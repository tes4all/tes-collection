#!/bin/bash
set -e

# Integration Test for Postgres-HA Golden Stack
# Usage: ./run.sh [local|remote]

MODE=${1:-local}
SCRIPT_DIR=$(dirname "$0")
cd "$SCRIPT_DIR"

echo "=== Running Postgres-HA Integration Test ($MODE) ==="

# 1. Select Compose File
COMPOSE_FILE="compose.local.yaml"
if [ "$MODE" == "remote" ]; then
    COMPOSE_FILE="compose.remote.yaml"
fi

# 2. Validate Config
echo "Validating config..."
docker compose -f $COMPOSE_FILE config > /dev/null

# 3. Build & Run Stack
echo "Building images..."
docker compose -f $COMPOSE_FILE build

echo "Starting stack..."
docker compose -f $COMPOSE_FILE up -d

# 4. Wait for cluster initialization
echo "Waiting for cluster initialization (90s)..."
sleep 90

# 5. Verify etcd cluster
echo "Verifying etcd cluster..."
for node in etcd-1 etcd-2 etcd-3; do
    if docker compose -f $COMPOSE_FILE ps "$node" | grep -q "healthy"; then
        echo "  ✅ $node is healthy"
    else
        echo "  ❌ $node is NOT healthy"
        docker compose -f $COMPOSE_FILE logs "$node"
        docker compose -f $COMPOSE_FILE down -v
        exit 1
    fi
done

# 6. Verify Patroni cluster
echo "Verifying Patroni cluster..."
CLUSTER_STATUS=$(docker compose -f $COMPOSE_FILE exec -T postgres-1 \
    curl -s http://localhost:8008/cluster 2>/dev/null || echo "{}")

LEADER=$(echo "$CLUSTER_STATUS" | python3 -c \
    "import sys,json; m=json.load(sys.stdin).get('members',[]); print([x['name'] for x in m if x.get('role')=='leader'][0] if m else '')" 2>/dev/null)

if [ -n "$LEADER" ]; then
    echo "  ✅ Leader: $LEADER"
else
    echo "  ❌ No leader elected"
    docker compose -f $COMPOSE_FILE down -v
    exit 1
fi

# 7. Verify HAProxy
echo "Verifying HAProxy..."
if docker compose -f $COMPOSE_FILE exec -T postgres-1 \
    psql "postgresql://postgres:postgres@dbha:5000/postgres?sslmode=require" \
    -c "SELECT 1;" > /dev/null 2>&1; then
    echo "  ✅ HAProxy primary endpoint (5000) works"
else
    echo "  ❌ HAProxy primary endpoint failed"
    docker compose -f $COMPOSE_FILE down -v
    exit 1
fi

# 8. Verify write + read
echo "Testing write/read..."
docker compose -f $COMPOSE_FILE exec -T "$LEADER" psql -U postgres -c \
    "CREATE TABLE IF NOT EXISTS integration_test (id SERIAL, msg TEXT); INSERT INTO integration_test (msg) VALUES ('integration-ok');" > /dev/null 2>&1
if docker compose -f $COMPOSE_FILE exec -T "$LEADER" psql -U postgres -c \
    "SELECT msg FROM integration_test;" 2>/dev/null | grep -q "integration-ok"; then
    echo "  ✅ Write/read through Postgres works"
else
    echo "  ❌ Write/read failed"
    docker compose -f $COMPOSE_FILE down -v
    exit 1
fi

# 9. Verify metrics
echo "Verifying metrics endpoints..."
if docker compose -f $COMPOSE_FILE exec -T postgres-1 curl -sf http://dbha:8405/metrics > /dev/null 2>&1; then
    echo "  ✅ HAProxy metrics available"
else
    echo "  ⚠️  HAProxy metrics not available yet"
fi

# 10. Teardown
echo "Tearing down..."
docker compose -f $COMPOSE_FILE down -v

echo ""
echo "=== Integration test ($MODE) PASSED ==="
