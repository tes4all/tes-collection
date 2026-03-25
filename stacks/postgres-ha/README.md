# Postgres HA Golden Stack

Production-ready PostgreSQL High Availability cluster using Patroni, etcd, HAProxy, and pgBackRest. This is a **Golden Stack** — deploy it as-is and connect your services via the shared Docker network. You never need to modify this compose file.

## Architecture

### Components

| Component | Version | Purpose |
|-----------|---------|---------|
| **PostgreSQL** | 18.1 | Primary database engine |
| **Patroni** | 3.2.0 | HA orchestration and automatic failover |
| **etcd** | 3.5.11 | Distributed consensus (3-node cluster) |
| **HAProxy** | 3.0.7 (LTS) | Connection load balancer (primary + replicas) |
| **pgBackRest** | latest | Enterprise-grade backup and restore |
| **postgres_exporter** | 0.16.0 | Prometheus metrics for PostgreSQL |

### Topology

```
                        ┌──────────────────────────────────┐
                        │      Your Application(s)         │
                        │  (any service on postgres-ha net) │
                        └──────────┬───────────────────────┘
                                   │
                    postgresql://dbha:5000  (write)
                    postgresql://dbha:5001  (read)
                                   │
                  ┌────────────────▼────────────────┐
                  │     HAProxy (2 replicas)        │
                  │  :5000 → primary (read-write)   │
                  │  :5001 → replicas (read-only)   │
                  │  :8405 → prometheus metrics     │
                  └────┬────────────┬───────────┬───┘
                       │            │           │
              ┌────────▼──┐  ┌─────▼─────┐  ┌──▼────────┐
              │ postgres-1 │  │ postgres-2│  │ postgres-3│
              │ (Patroni)  │  │ (Patroni) │  │ (Patroni) │
              │  :5432     │  │  :5432    │  │  :5432    │
              │  :8008 API │  │  :8008    │  │  :8008    │
              └──────┬─────┘  └─────┬─────┘  └─────┬────┘
                     │              │              │
              ┌──────▼──────────────▼──────────────▼────┐
              │         etcd Cluster (3 nodes)          │
              │  etcd-1:2379 │ etcd-2:2379 │ etcd-3:2379│
              └─────────────────────────────────────────┘
                                   │
              ┌────────────────────▼────────────────────┐
              │   pgBackRest  (automated backups)       │
              │   postgres-exporter (Prometheus)        │
              └─────────────────────────────────────────┘
```

## Quick Start

### 1. Configure Environment

```bash
cd stacks/postgres-ha

# Copy and edit the environment file
cp .env.example .env

# Edit passwords (REQUIRED for production!)
vim .env
```

**`.env` variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK_DRIVER` | `overlay` | `bridge` for local Docker Compose, `overlay` for Swarm |
| `POSTGRES_PASSWORD` | `postgres` | PostgreSQL superuser password |
| `REPLICATOR_PASSWORD` | `replicator` | Streaming replication password |
| `ADMIN_PASSWORD` | `admin` | Admin user password |

### 2a. Local Development (Docker Compose)

```bash
# Set bridge networking for local use
echo "NETWORK_DRIVER=bridge" > .env

# Build and start
docker compose build
docker compose up -d

# Wait ~90 seconds for cluster initialization, then verify
./tests/verify.sh
```

### 2b. Production (Docker Swarm)

```bash
# Initialize swarm (if not already)
docker swarm init

# Build images on all nodes (or push to a registry)
docker compose build

# Deploy as a stack (uses overlay networking by default)
docker stack deploy -c compose.yaml postgres-ha

# Check service status
docker stack services postgres-ha
```

### 3. Connect Your Application

From any service on the same Docker Swarm / Compose network:

```
# Read-Write (always reaches the current primary)
postgresql://postgres:<password>@dbha:5000/mydb?sslmode=require

# Read-Only (load-balanced across replicas)
postgresql://postgres:<password>@dbha:5001/mydb?sslmode=require
```

See [`examples/compose.consumer.yaml`](examples/compose.consumer.yaml) for a complete example.

## Connecting from Other Projects

### Option A: Include locally (mono-repo)

```yaml
# your-project/compose.yaml
include:
  - path: ./stacks/postgres-ha/compose.yaml

services:
  my-app:
    image: my-app:latest
    networks:
      - postgres-ha
    environment:
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD:-postgres}@dbha:5000/mydb?sslmode=require
```

### Option B: Include from Git (remote)

```yaml
include:
  - https://github.com/tes4all/tes.git#main:stacks/postgres-ha/compose.yaml
```

### Option C: Deploy separately, reference network (recommended for Swarm)

Deploy the golden stack once:
```bash
docker stack deploy -c stacks/postgres-ha/compose.yaml postgres-ha
```

Then in your application's compose:
```yaml
services:
  my-app:
    image: my-app:latest
    networks:
      - postgres-ha
    environment:
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@dbha:5000/mydb?sslmode=require

networks:
  postgres-ha:
    external: true
```

The network is named `postgres-ha` (no stack prefix) because the golden compose uses `name: postgres-ha`.

## Security

### Features

- **No ports exposed to host** — database is accessible only through the Docker overlay network
- **scram-sha-256** authentication (not md5)
- **SSL/TLS enforced** for all connections
- **Non-root containers** — all services run as unprivileged users
- **Baked configurations** — all configs copied into images at build time (no bind-mounts)
- **Version pinning** — no `:latest` tags
- **Capability dropping** — `CAP_DROP: ALL` with minimal required caps added back
- **no-new-privileges** — prevents privilege escalation
- **read_only** rootfs where possible
- **Structured logging** with size limits (`max-size: 10m`, `max-file: 3`)

### Password Management

**Local development:** Set passwords in `.env` file (loaded via Docker Compose variable substitution).

**Production (Docker Swarm with Docker Secrets):**

```bash
# Create secrets
echo "super_secure_pg_password" | docker secret create postgres_password -
echo "super_secure_replicator"  | docker secret create replicator_password -
echo "super_secure_admin"       | docker secret create admin_password -
```

The entrypoint automatically reads files from `/run/secrets/` and exports them as environment variables. Secret file names map to env vars:

| Secret file | Env var |
|-------------|---------|
| `/run/secrets/postgres_password` | `POSTGRES_PASSWORD` |
| `/run/secrets/replicator_password` | `REPLICATOR_PASSWORD` |
| `/run/secrets/admin_password` | `ADMIN_PASSWORD` |

To mount secrets in Swarm, create a thin overlay compose or use `docker service update`:
```bash
docker service update --secret-add postgres_password postgres-ha_postgres-1
```

### Default Credentials (Development Only!)

| User | Password | Purpose |
|------|----------|---------|
| `postgres` | `postgres` | Superuser |
| `admin` | `admin` | Admin (createrole, createdb) |
| `replicator` | `replicator` | Streaming replication |

> **Warning**: Change ALL passwords before any production deployment!

## Monitoring & Observability

### Prometheus Metrics Endpoints

All services expose metrics on the internal network (not on the host). Your Prometheus instance must be on the `postgres-ha` network.

| Service | Endpoint | Metrics |
|---------|----------|---------|
| HAProxy | `dbha:8405/metrics` | Connection counts, backend health, latency |
| Patroni (per node) | `postgres-{1,2,3}:8008/metrics` | Cluster role, replication lag, timeline |
| postgres_exporter | `postgres-exporter:9187/metrics` | Query stats, table sizes, locks, cache hit ratio |

All services carry Prometheus auto-discover labels:
```yaml
labels:
  - "prometheus.scrape=true"
  - "prometheus.port=<port>"
  - "prometheus.path=/metrics"
```

### Key Metrics for Grafana Dashboards

| What to monitor | Metric / Query |
|----------------|----------------|
| Replication lag | `pg_stat_replication_replay_lag` |
| Active connections | `pg_stat_activity_count` |
| Cache hit ratio | `pg_stat_database_blks_hit / (blks_hit + blks_read)` |
| Transaction rate | `rate(pg_stat_database_xact_commit[5m])` |
| HAProxy backend health | `haproxy_server_status` |
| HAProxy connection queue | `haproxy_backend_current_queue` |
| Slow queries | `pg_stat_statements_mean_time_seconds` |
| Disk usage | `pg_database_size_bytes` |

### Grafana Setup

Connect your Prometheus to any of the metrics endpoints above. Recommended community dashboards:

- **PostgreSQL**: [Grafana Dashboard #9628](https://grafana.com/grafana/dashboards/9628) (postgres_exporter)
- **HAProxy**: [Grafana Dashboard #2428](https://grafana.com/grafana/dashboards/2428) (HAProxy Prometheus)
- **Patroni**: [Grafana Dashboard #18870](https://grafana.com/grafana/dashboards/18870)

Example Prometheus scrape config:
```yaml
scrape_configs:
  - job_name: 'postgres-ha-dbha'
    dns_sd_configs:
      - names: ['tasks.dbha']
        type: A
        port: 8405
  - job_name: 'postgres-ha-exporter'
    static_configs:
      - targets: ['postgres-exporter:9187']
  - job_name: 'postgres-ha-patroni'
    static_configs:
      - targets: ['postgres-1:8008', 'postgres-2:8008', 'postgres-3:8008']
```

### Health & Cluster Status

```bash
# Patroni cluster status (from inside a container on the network)
docker compose exec postgres-1 curl -s http://localhost:8008/cluster | python3 -m json.tool

# Which node is the leader?
docker compose exec postgres-1 curl -s http://localhost:8008/cluster | \
  python3 -c "import sys,json; m=json.load(sys.stdin)['members']; [print(x['name'],x['role']) for x in m]"

# Replication lag
docker compose exec postgres-1 psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

## High Availability

- **Automatic failover**: Patroni detects primary failure and promotes a replica within ~30s
- **Streaming replication**: Real-time data sync across all nodes
- **Split-brain protection**: etcd consensus ensures only one primary at any time
- **HAProxy health checks**: Routes traffic only to healthy nodes (checks Patroni API every 3s)
- **2x HAProxy replicas**: HAProxy itself is HA — Docker Swarm load-balances between instances with `start-first` rolling updates
- **Quorum-based**: 3-node etcd cluster tolerates 1 node failure

### Test Failover

```bash
# Stop the current primary
docker compose stop postgres-1

# Watch Patroni elect a new leader (~30 seconds)
docker compose exec postgres-2 curl -s http://localhost:8008/cluster | python3 -m json.tool

# HAProxy automatically routes to the new primary — zero application changes needed

# Restart the old primary (becomes a replica)
docker compose start postgres-1
```

## Backups (pgBackRest)

- **Automated incremental backups** every hour
- **Point-in-time recovery (PITR)** with full WAL archiving
- **LZ4 compression** for efficient storage
- **Configurable retention**: 2 full + 4 differential backups (see `config/pgbackrest.conf`)

```bash
# Manual full backup
docker compose exec pgbackrest pgbackrest --stanza=postgres-cluster backup --type=full

# List backups
docker compose exec pgbackrest pgbackrest info

# Restore (requires cluster stop)
docker compose exec pgbackrest pgbackrest --stanza=postgres-cluster restore
```

## Configuration

### File Structure

```
stacks/postgres-ha/
├── compose.yaml              # Golden Stack — DO NOT MODIFY per deployment
├── .env.example              # Environment variable template
├── Dockerfile.patroni        # PostgreSQL + Patroni image
├── Dockerfile.pgbackrest     # Backup image
├── Dockerfile.haproxy        # HAProxy LB image (baked config)
├── entrypoint.sh             # Secrets + envsubst templating
├── config/
│   ├── patroni.yml           # Patroni config template (envsubst'd at runtime)
│   ├── postgres.conf         # PostgreSQL tuning
│   ├── pg_hba.conf           # Client authentication
│   ├── pgbackrest.conf       # Backup configuration
│   └── haproxy.cfg           # HAProxy load balancer config
├── examples/
│   └── compose.consumer.yaml # Example: how to connect from another project
└── tests/
    ├── verify.sh             # Comprehensive test suite
    └── integration/
        ├── run.sh            # Integration test runner
        ├── compose.local.yaml   # Local include
        └── compose.remote.yaml  # Remote Git include
```

### Tuning PostgreSQL

Edit `config/postgres.conf` and rebuild:

```bash
docker compose build
docker compose up -d
```

Key parameters:
- `shared_buffers`: 25% of available RAM (default: 256MB)
- `effective_cache_size`: 75% of available RAM (default: 1GB)
- `work_mem`: Per-sort memory (default: 4MB)
- `max_connections`: Max client connections (default: 100)

### Network Configuration

The network driver is configurable via `.env` — the compose.yaml is never modified:

| Mode | `.env` setting | Use case |
|------|---------------|----------|
| Local | `NETWORK_DRIVER=bridge` | `docker compose up` development |
| Swarm | `NETWORK_DRIVER=overlay` (default) | `docker stack deploy` production |

The network is always named `postgres-ha` (with `name: postgres-ha` in compose) so consumers can reference it as `external: true` without worrying about stack name prefixes.

## Testing

### Quick Verification

```bash
./tests/verify.sh
```

Tests: etcd health, Patroni cluster, database read/write, HAProxy primary + replicas, replication, metrics endpoints, SSL, scram-sha-256, security hardening.

### Integration Tests

```bash
# Local (includes compose.yaml with bridge network)
./tests/integration/run.sh local

# Remote (includes compose.yaml from GitHub)
./tests/integration/run.sh remote
```

## Production Checklist

- [ ] Change all passwords in `.env` (or use Docker Secrets)
- [ ] Replace self-signed SSL certificates with CA-signed certs
- [ ] Set `NETWORK_DRIVER=overlay` (default)
- [ ] Adjust `shared_buffers` / `effective_cache_size` for your server RAM
- [ ] Configure backup retention in `config/pgbackrest.conf`
- [ ] Set up Prometheus scraping for all metrics endpoints
- [ ] Build Grafana dashboards for query performance, replication lag, connections
- [ ] Set up alerting (replication lag > 1MB, primary down, HAProxy backend down)
- [ ] Test failover scenarios thoroughly
- [ ] Document recovery procedures
- [ ] Configure log aggregation
- [ ] Review firewall rules — ensure overlay network is not exposed

## Troubleshooting

### Cluster Won't Initialize

```bash
# Check etcd health
docker compose exec etcd-1 etcdctl endpoint health --cluster

# Check Patroni logs
docker compose logs postgres-1

# Reset and retry
docker compose down -v
docker compose up -d
```

### Replication Lag

```bash
docker compose exec postgres-1 psql -U postgres -c \
  "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"
```

### Can't Connect from Another Service

1. Verify the service is on the `postgres-ha` network
2. Use `dbha:5000` (not direct postgres nodes)
3. Use `sslmode=require` in connection string
4. Check password matches `POSTGRES_PASSWORD` in `.env`

### HAProxy Shows No Healthy Backends

```bash
# Check HAProxy stats
docker compose exec postgres-1 curl -s http://dbha:8405/stats

# Check Patroni health on each node
for n in postgres-1 postgres-2 postgres-3; do
  echo "$n: $(docker compose exec -T $n curl -s http://localhost:8008/health)"
done
```

## Architecture Decisions

| Decision | Rationale |
|----------|-----------|
| **Patroni** | Industry-standard PG HA, automatic failover, active community |
| **etcd** | Lightweight consensus, proven at scale (Kubernetes uses it) |
| **HAProxy** | L4 TCP load balancer, uses Patroni REST API for health checks |
| **No host ports** | Security — DB accessible only within Docker network |
| **envsubst templating** | Enables password injection without modifying baked configs |
| **scram-sha-256** | Modern password auth, replaces deprecated md5 |
| **Bridge/overlay via .env** | Golden stack works for both local dev and Swarm without changes |

## License

This stack configuration is provided as-is for use in the TES project.
