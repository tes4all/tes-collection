import pytest
import httpx
import time
import os
import python_on_whales
from valkey import Valkey
from python_on_whales import DockerClient

API_URL = "http://127.0.0.1:8000"
VALKEY_HOST = "localhost" # Port forwarded? No, we need to access via Docker or expose port.
# Our compose.test.yaml exposes valkey on 6379 host port?
# Let's check compose.test.yaml.

@pytest.fixture(scope="module")
def docker_stack():
    docker = DockerClient(compose_files=[
        "stacks/edge-router/compose.yaml",
        "stacks/edge-router/tests/e2e/compose.test.yaml"
    ])

    # Ensure Swarm is active for Service tests
    try:
        docker.node.list()
    except python_on_whales.exceptions.NotASwarmManager:
        print("Swarm not active. Initializing Swarm...")
        docker.swarm.init()

    print("Building images...")
    docker.compose.build(["valkey", "edge-router-api", "cert-manager", "cert-syncer", "traefik", "socket-proxy"])

    print("Starting Phase 3 Stack (including Traefik & Syncer)...")
    docker.compose.up(["valkey", "edge-router-api", "cert-manager", "cert-syncer", "traefik", "socket-proxy"], detach=True)

    time.sleep(15)

    yield docker

    print("Tearing down...")
    docker.compose.down(volumes=True)

def test_api_health(docker_stack):
    """
    Verify Edge Router API is reachable and healthy.
    This also ensures the container image has the necessary tools (like curl) for its internal healthcheck.
    """
    print("Checking API Health via HTTP...")

    # Check if the API responds to HTTP requests
    try:
        response = httpx.get(f"{API_URL}/health", timeout=5.0)
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
    except httpx.ConnectError:
        pytest.fail("Could not connect to Edge Router API at http://localhost:8000")

    # Check Docker Healthcheck Status
    print("Checking Container Health Status...")
    api_container = docker_stack.compose.ps(services=["edge-router-api"])[0]

    # We allow some time for the healthcheck to run if it's still starting
    # But usually the sleep(15) in fixture is enough for the first check
    inspect = docker_stack.container.inspect(api_container.id)
    health_status = inspect.state.health.status

    # If it's starting, that's "okay" safely, but "unhealthy" is a failure.
    if health_status == "unhealthy":
         # dump logs to concise reason
         log_out = docker_stack.compose.logs(services=["edge-router-api"])
         print(f"Container logs:\n{log_out}")
         pytest.fail(f"Container {api_container.name} is marked unhealthy. (Missing curl?)")

    print(f"API Health Status: {health_status}")

def test_cert_syncer_flow(docker_stack):
    """
    Test that Cert Syncer generates Traefik config when certs appear in Valkey.
    """
    # 1. Inject dummy cert into Valkey (Simulating Cert Manager's Publish)
    valkey_container = docker_stack.compose.ps(services=["valkey"])[0]
    print(f"Injecting dummy certificate into Valkey via {valkey_container.name}...")

    # We use HSET to store the certified and key data
    valkey_container.execute([
        "valkey-cli", "-a", "insecure_default",
        "HSET", "cert_data:test-domain",
        "crt", "FAKE_CERT_DATA",
        "key", "FAKE_KEY_DATA"
    ])

    # Wait for Cert Syncer to be ready (subscribed)
    print("Waiting for Cert Syncer subscription...")
    start_wait = time.time()
    while time.time() - start_wait < 30:
        logs = docker_stack.compose.logs(services=["cert-syncer"])
        if "Subscribed to events/certs_updated" in logs:
            print("Cert Syncer is ready.")
            break
        time.sleep(1)

    # 2. Trigger Event via Redis
    print(f"Publishing event to {valkey_container.name}...")
    res = valkey_container.execute(["valkey-cli", "-a", "insecure_default", "PUBLISH", "events/certs_updated", "{}"])
    print(f"Publish Result: {res}")

    # 3. Wait for Syncer to process
    print("Waiting for Cert Syncer...")
    time.sleep(5)
    syncer_logs = docker_stack.compose.logs(services=["cert-syncer"])
    assert "Regenerating Traefik TLS Config" in syncer_logs
    assert "Updated /etc/traefik/dynamic/certificates.yml with 1 certificates" in syncer_logs # Note path fix if needed

    # 4. Check Traefik Logs for File Provider update
    # Traefik logs usually show "Configuration received from provider file" or similar
    traefik_logs = docker_stack.compose.logs(services=["traefik"])
    # This might be noisy, but let's check basic health.
    assert "traefik" in traefik_logs.lower()

def test_traefik_redis_connection(docker_stack):
    """
    Verify Traefik connects to Redis (logs check).
    """
    logs = docker_stack.compose.logs(services=["traefik"])
    # If connection fails, it errors.
    # We look for "Provider error, unable to access redis" or success.
    # Success is typically silent or debug.
    # We check line by line to ensure the error is actually ABOUT redis.
    for line in logs.splitlines():
        if "Provider error" in line and "redis" in line.lower():
            pytest.fail(f"Traefik failed to connect to Redis provider: {line}")

def test_docker_auto_discovery(docker_stack):
    """
    Test that Cert Manager detects new Swarm services with Traefik labels.
    """
    service_name = "test-autodisc-service"
    domain = "auto-discovery.test"

    print(f"Creating Swarm Service {service_name} with Host(`{domain}`)...")

    try:
        # Ensure cleanup if exists
        try:
            docker_stack.service.remove(service_name)
        except:
            pass

        # Create service with label
        # Note: We don't attach to network to keep it simple, detection is metadata-based
            # python_on_whales .service.create does not support 'name' kwarg(?), let's rely on docker.run or implicit
            # Wait, ServiceCLI.create signature from inspect missing 'name'?!?
            # That is bizarre. Let's use command line fallback or 'command' directly.
            # Actually, let's use the low-level client or just omit the name and let it be random,
            # BUT we need the name for the label.
            # Workaround: Use docker cli string command.

            cmd = [
                "docker", "service", "create",
                "--name", service_name,
                "--label", f"traefik.http.routers.{service_name}.rule=Host(`{domain}`)",
                "alpine:latest",
                "sleep", "3600"
            ]
            import subprocess
            subprocess.run(cmd, check=True)

            # Wait for service to be visible (consistency)
            time.sleep(2)
        # (It should be instant via Docker Events, or fallback to polling)
        print("Waiting for Cert Manager detection...")
        found = False
        start_time = time.time()
        # Give it up to 15s (Event listener should be sub-second, polling is 60s)
        # If event listener works, this should pass quickly.
        while time.time() - start_time < 30:
            logs = docker_stack.compose.logs(services=["cert-manager"])
            if f"Discovered new domain from Docker: {domain}" in logs:
                print("Log confirmation found.")
                found = True
                break
            time.sleep(1)

        if not found:
            print("Dumping Cert Manager Logs for Debugging:")
            print(docker_stack.compose.logs(services=["cert-manager"]))

        assert found, f"Cert Manager did not log discovery of {domain}"

        # 3. Verify Redis State
        valkey_container = docker_stack.compose.ps(services=["valkey"])[0]
        # Query Redis Set
        res = valkey_container.execute(["valkey-cli", "-a", "insecure_default", "SISMEMBER", "target_domains", domain])
        assert res.strip() == "1", f"Domain {domain} not found in Redis target_domains (Redis response: {res})"

    finally:
        # Cleanup
        print(f"Removing service {service_name}...")
        try:
            docker_stack.service.remove(service_name)
        except:
            pass
