#!/usr/bin/env python3
import os
import re
import sys
import requests
from packaging.version import parse as parse_version, InvalidVersion

# Regex for Dockerfile FROM instruction
# FROM image:tag AS ...
DOCKERFILE_FROM_RE = re.compile(r'^(FROM\s+)([^:\s]+):([a-zA-Z0-9.\-_]+)(\s+AS.*)?$', re.IGNORECASE)

# Regex for Compose image instruction
# image: image:tag
COMPOSE_IMAGE_RE = re.compile(r'^(\s*image:\s+)([^:\s]+):([a-zA-Z0-9.\-_]+)(\s*)$')
# image: image:${VAR:-tag}
COMPOSE_VAR_RE = re.compile(r'^(\s*image:\s+)([^:\s]+):\$\{([A-Z0-9_]+):-([a-zA-Z0-9.\-_]+)\}(\s*)$')


def get_docker_tags(image_name):
    """
    Get list of tags for an image from Docker Hub, GHCR, Quay, etc.
    """
    registry = "docker.io"
    repo = image_name

    if "/" in image_name:
        parts = image_name.split("/")
        first_part = parts[0]
        # Heuristic to detect registry domain
        if "." in first_part or ":" in first_part or first_part == "localhost":
            registry = first_part
            repo = "/".join(parts[1:])
    else:
        repo = f"library/{image_name}"

    if registry == "docker.io":
        if not repo.startswith("library/") and "/" not in repo:
            repo = f"library/{repo}"
        url = f"https://hub.docker.com/v2/repositories/{repo}/tags/?page_size=100"
        tags = []
        try:
            while url:
                resp = requests.get(url, timeout=10)
                if resp.status_code != 200:
                    print(f"Failed to fetch tags for {image_name}: {resp.status_code}")
                    return tags
                data = resp.json()
                for r in data.get('results', []):
                    tags.append(r['name'])
                url = data.get('next')
                if len(tags) >= 1000:
                    break
        except Exception as e:
            print(f"Error fetching tags for {image_name}: {e}")
            pass
        return tags

    elif registry == "quay.io":
         url = f"https://quay.io/api/v1/repository/{repo}/tag/"
         try:
             resp = requests.get(url, timeout=10)
             if resp.status_code == 200:
                 return [t['name'] for t in resp.json().get('tags', [])]
             else:
                 print(f"Failed to fetch tags for {image_name}: {resp.status_code}")
         except Exception as e:
             print(f"Error fetching tags for {image_name}: {e}")
             pass
         return []

    else:
        try:
            url = f"https://{registry}/v2/{repo}/tags/list"
            resp = requests.get(url, timeout=10)

            if resp.status_code == 401:
                auth_header = resp.headers.get("WWW-Authenticate", "")
                if 'Bearer' in auth_header:
                    params = {}
                    for match in re.finditer(r'([A-Za-z0-9_-]+)="([^"]+)"', auth_header):
                        params[match.group(1)] = match.group(2)

                    if 'realm' in params:
                        auth_url = params['realm']
                        req_params = {}
                        if 'service' in params:
                            req_params['service'] = params['service']
                        if 'scope' in params:
                            req_params['scope'] = params['scope']

                        token_resp = requests.get(auth_url, params=req_params, timeout=10)
                        if token_resp.status_code == 200:
                            token = token_resp.json().get("token") or token_resp.json().get("access_token")
                            if token:
                                resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=10)

            if resp.status_code == 200:
                data = resp.json()
                tags = data.get("tags", [])

                # Check for pagination in Link header
                link_header = resp.headers.get("Link")
                while link_header and len(tags) < 2500:
                     match = re.search(r'<([^>]+)>; rel="next"', link_header)
                     if match:
                         next_path = match.group(1)
                         next_url = f"https://{registry}{next_path}"
                         headers = {}
                         if 'token' in locals():
                             headers["Authorization"] = f"Bearer {token}"
                         resp = requests.get(next_url, headers=headers, timeout=10)
                         if resp.status_code == 200:
                             tags.extend(resp.json().get("tags", []))
                             link_header = resp.headers.get("Link")
                         else:
                             break
                     else:
                         break

                return tags
            else:
                print(f"Failed to fetch tags for {image_name}: {resp.status_code} {resp.text}")
        except Exception as e:
            print(f"Error fetching tags for {image_name}: {e}")
            pass

    return []

def get_newer_version(current_tag, available_tags):
    """
    Find the newest version in available_tags that is greater than current_tag
    and matches the same suffix pattern (e.g. -alpine).
    """
    # 1. Identify suffix content (e.g. -alpine, -slim, or nothing)
    # We assume distinct parts separated by '-'.
    # If version is 1.2.3-alpine, version part is 1.2.3, suffix is -alpine.

    prefix_v = ""
    if current_tag.startswith('v') and len(current_tag) > 1 and current_tag[1].isdigit():
        prefix_v = "v"
        current_tag = current_tag[1:]

    version_part = current_tag
    suffix = ""

    # Heuristic: split by first hyphen if it looks like a version number
    match = re.match(r'^([0-9]+\.[0-9]+(?:\.[0-9]+)?)(.*)$', current_tag)
    if match:
        version_part = match.group(1)
        suffix = match.group(2)
    else:
        # Check for simple integer versions like '15-alpine'
        match_int = re.match(r'^([0-9]+)(.*)$', current_tag)
        if match_int:
            version_part = match_int.group(1)
            suffix = match_int.group(2)
        else:
            return None # Cannot parse version structure

    try:
        current_ver = parse_version(version_part)
    except InvalidVersion:
        return None

    best_ver = current_ver
    best_tag = None

    for tag in available_tags:
        if prefix_v:
            if not tag.startswith('v'):
                continue
            working_tag = tag[1:]
        else:
            if tag.startswith('v') and len(tag) > 1 and tag[1].isdigit():
                continue
            working_tag = tag

        # Must match suffix
        if not working_tag.endswith(suffix) if suffix else False:
            if suffix:
                continue
        elif suffix and not working_tag.endswith(suffix):
            continue

        # Extract version part from tag
        # It must match the structure: version_part + suffix
        # e.g. if suffix is -alpine, tag must be Something-alpine.
        # And Something must be a valid version.

        tag_version_str = working_tag[:-len(suffix)] if suffix else working_tag

        # Avoid matching completely different tags that happen to end with same suffix
        # e.g. 'latest-alpine' vs '3.19-alpine'.
        # We only want numeric versions.
        if not re.match(r'^[0-9]+\.[0-9]+(?:\.[0-9]+)?$', tag_version_str) and not re.match(r'^[0-9]+$', tag_version_str):
             continue

        try:
            tag_ver = parse_version(tag_version_str)
            if tag_ver > best_ver and not tag_ver.is_prerelease:
                best_ver = tag_ver
                best_tag = tag
        except InvalidVersion:
            continue

    return best_tag

def process_file(filepath):
    print(f"Scanning {filepath}...")
    with open(filepath, 'r') as f:
        lines = f.readlines()

    new_lines = []
    changed = False

    for line in lines:
        # Check Dockerfile
        m_docker = DOCKERFILE_FROM_RE.match(line)
        m_compose = COMPOSE_IMAGE_RE.match(line)
        m_compose_var = COMPOSE_VAR_RE.match(line)

        replacement = None

        if m_docker:
            prefix, image, tag, suffix = m_docker.groups()
            tags = get_docker_tags(image)
            newer = get_newer_version(tag, tags)
            if newer:
                print(f"  {image}: {tag} -> {newer}")
                replacement = f"{prefix}{image}:{newer}{suffix or ''}\n"

        elif m_compose:
            prefix, image, tag, suffix = m_compose.groups()
            tags = get_docker_tags(image)
            newer = get_newer_version(tag, tags)
            if newer:
                print(f"  {image}: {tag} -> {newer}")
                replacement = f"{prefix}{image}:{newer}{suffix}\n"

        elif m_compose_var:
            prefix, image, var_name, tag, suffix = m_compose_var.groups()
            tags = get_docker_tags(image)
            newer = get_newer_version(tag, tags)
            if newer:
                print(f"  {image}: {tag} -> {newer} (in var {var_name})")
                replacement = f"{prefix}{image}:${{{var_name}:-{newer}}}{suffix}\n"

        if replacement:
            new_lines.append(replacement)
            changed = True
        else:
            new_lines.append(line)

    if changed:
        with open(filepath, 'w') as f:
            f.writelines(new_lines)
        print(f"Updated {filepath}")

def main():
    if len(sys.argv) < 2:
        print("Usage: update_docker_images.py [directory]")
        sys.exit(1)

    root_dir = sys.argv[1]

    for root, dirs, files in os.walk(root_dir):
        if ".git" in dirs:
            dirs.remove(".git")
        if ".venv" in dirs:
            dirs.remove(".venv")

        for file in files:
            if file.startswith("Dockerfile") or file == "compose.yaml" or file == "compose.yml":
                process_file(os.path.join(root, file))

if __name__ == "__main__":
    main()
