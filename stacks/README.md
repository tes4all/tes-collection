# Golden Stacks

This directory contains production-ready "Golden Stacks" optimized for Docker Swarm but compatible with Docker Compose. Each stack is self-contained with baked configurations, non-root users, and built-in observability.

## Available Stacks

*   **[authentik](./authentik)**: Identity Provider (IdP) with Valkey caching.
*   **[edge-router](./edge-router)**: HAProxy (L4) and Traefik (L7) ingress controller.
*   **[postgres-ha](./postgres-ha)**: High-availability PostgreSQL cluster using Patroni and etcd.
*   **[vaultwarden](./vaultwarden)**: Bitwarden compatible password manager.
*   **[zitadel](./zitadel)**: Identity infrastructure and IAM.

## Usage

These stacks are designed to be imported into a main `compose.yaml` file using the Docker Compose `include` feature. This allows you to compose a complex infrastructure from modular, pre-configured blocks.

### Example

See `tests/import-test/compose.yaml` for a working example of how to import all stacks.

```yaml
include:
  - https://github.com/tes4all/tes/blob/main/stacks/edge-router/compose.yaml
  - https://github.com/tes4all/tes/blob/main/stacks/postgres-ha/compose.yaml
  - https://github.com/tes4all/tes/blob/main/stacks/authentik/compose.yaml
```

## Configuration

Each stack is configured primarily through **Environment Variables**. You should set these variables in your project's `.env` file or your deployment environment.

Refer to each stack's README for a complete list of available configuration options.

### Common Configuration Pattern

1.  **Check the Stack README**: Find the "Configuration" section in the stack's folder (e.g., `stacks/authentik/README.md`).
2.  **Set Variables**: Add the required variables to your `.env` file.
3.  **Deploy**: Run `docker compose up -d` or `docker stack deploy`.

### Example `.env`

```bash
# Authentik
AUTHENTIK_SECRET_KEY=<authentik_secret_key_placeholder>
POSTGRES_PASSWORD=<postgres_password_placeholder>

# Vaultwarden
DOMAIN=https://vault.example.com
SIGNUPS_ALLOWED=false

# Zitadel
ZITADEL_MASTERKEY=<zitadel_masterkey_placeholder_32_bytes_min>
```

## Testing

You can verify that all stacks can be imported correctly by running the integration test:

```bash
./stacks/tests/import-test/verify.sh
```
