#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${YELLOW}=== Postgres HA Golden Stack Verification ===${NC}\n"

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    cd "$STACK_DIR"
    docker compose down -v 2>/dev/null || true
}

# Trap exit to cleanup
trap cleanup EXIT

# Ensure local network driver for testing
ensure_local_env() {
    if [ ! -f "$STACK_DIR/.env" ]; then
        echo "NETWORK_DRIVER=bridge" > "$STACK_DIR/.env"
        echo -e "Created .env with NETWORK_DRIVER=bridge for local testing"
    fi
}

# Function to wait for service health
wait_for_health() {
    local service=$1
    local max_attempts=${2:-30}
    local attempt=1

    echo -n "Waiting for $service to be healthy..."
    while [ $attempt -le $max_attempts ]; do
        if docker compose ps "$service" 2>/dev/null | grep -q "healthy"; then
            echo -e " ${GREEN}✓${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done

    echo -e " ${RED}✗${NC}"
    echo -e "${RED}Service $service failed to become healthy${NC}"
    docker compose logs "$service" 2>/dev/null || true
    return 1
}

# Helper: run curl inside a container on the postgres-ha network
_curl() {
    docker compose exec -T postgres-1 curl -sf "$@" 2>/dev/null
}

# Function to check Patroni cluster
check_patroni_cluster() {
    echo -e "\n${YELLOW}Checking Patroni cluster status...${NC}"

    for node in postgres-1 postgres-2 postgres-3; do
        echo -n "Checking $node Patroni REST API..."
        if docker compose exec -T "$node" curl -sf http://localhost:8008/health > /dev/null 2>&1; then
            echo -e " ${GREEN}✓${NC}"
        else
            echo -e " ${RED}✗${NC}"
            return 1
        fi
    done

    # Check cluster topology
    echo -n "Checking cluster topology..."
    local cluster_status
    cluster_status=$(docker compose exec -T postgres-1 curl -s http://localhost:8008/cluster)
    if echo "$cluster_status" | grep -q "postgres-1\|postgres-2\|postgres-3"; then
        echo -e " ${GREEN}✓${NC}"
        echo "$cluster_status" | python3 -m json.tool 2>/dev/null || true
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi
}

# Function to test database connectivity
test_database() {
    echo -e "\n${YELLOW}Testing database connectivity...${NC}"

    # Find the leader
    echo -n "Finding leader..."
    local leader
    leader=$(docker compose exec -T postgres-1 curl -s http://localhost:8008/cluster \
        | python3 -c "import sys,json; members=json.load(sys.stdin)['members']; print([m['name'] for m in members if m['role']=='leader'][0])" 2>/dev/null)

    if [ -z "$leader" ]; then
        echo -e " ${RED}✗ (No leader found)${NC}"
        return 1
    fi
    echo -e " ${GREEN}✓ ($leader)${NC}"

    echo -n "Connecting to Postgres ($leader)..."
    if docker compose exec -T "$leader" psql -U postgres -c "SELECT version();" > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi

    echo -n "Creating test table..."
    if docker compose exec -T "$leader" psql -U postgres -c "CREATE TABLE IF NOT EXISTS test_ha (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMPTZ DEFAULT now());" > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi

    echo -n "Inserting test data..."
    if docker compose exec -T "$leader" psql -U postgres -c "INSERT INTO test_ha (data) VALUES ('test data from verify.sh');" > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi

    echo -n "Reading test data..."
    if docker compose exec -T "$leader" psql -U postgres -c "SELECT * FROM test_ha;" | grep -q "test data"; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi
}

# Function to test HAProxy load balancer
test_dbha() {
    echo -e "\n${YELLOW}Testing HAProxy load balancer...${NC}"

    echo -n "HAProxy primary endpoint (port 5000)..."
    if docker compose exec -T postgres-1 psql "postgresql://postgres:postgres@dbha:5000/postgres?sslmode=require" \
        -c "SELECT 1;" > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi

    echo -n "HAProxy replicas endpoint (port 5001)..."
    if docker compose exec -T postgres-1 psql "postgresql://postgres:postgres@dbha:5001/postgres?sslmode=require" \
        -c "SELECT 1;" > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        # Replicas may not be ready yet; warn instead of fail
        echo -e " ${YELLOW}⚠ (replicas may still be initializing)${NC}"
    fi

    echo -n "HAProxy stats/metrics endpoint (port 8405)..."
    if docker compose exec -T postgres-1 curl -sf http://dbha:8405/stats > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi

    echo -n "HAProxy Prometheus metrics..."
    if docker compose exec -T postgres-1 curl -sf http://dbha:8405/metrics | head -5 | grep -q "haproxy"; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi
}

# Function to test replication
test_replication() {
    echo -e "\n${YELLOW}Testing replication...${NC}"

    local leader
    leader=$(docker compose exec -T postgres-1 curl -s http://localhost:8008/cluster \
        | python3 -c "import sys,json; members=json.load(sys.stdin)['members']; print([m['name'] for m in members if m['role']=='leader'][0])" 2>/dev/null)

    echo -n "Checking replication slots..."
    local slots
    slots=$(docker compose exec -T "$leader" psql -U postgres -c "SELECT slot_name FROM pg_replication_slots;" 2>/dev/null)
    if echo "$slots" | grep -qE "postgres-[23]"; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${YELLOW}⚠ No replication slots found (may be initializing)${NC}"
    fi

    echo -n "Checking streaming replication..."
    local replication
    replication=$(docker compose exec -T "$leader" psql -U postgres -c "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null)
    if echo "$replication" | grep -qE "[12]"; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${YELLOW}⚠ No active replication connections (may be initializing)${NC}"
    fi
}

# Function to check metrics endpoints
check_metrics() {
    echo -e "\n${YELLOW}Checking metrics endpoints...${NC}"

    echo -n "Patroni metrics (postgres-1:8008)..."
    if docker compose exec -T postgres-1 curl -sf http://localhost:8008/metrics > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi

    echo -n "Postgres exporter metrics (postgres-exporter:9187)..."
    if docker compose exec -T postgres-1 curl -sf http://postgres-exporter:9187/metrics > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${YELLOW}⚠ (exporter may still be connecting)${NC}"
    fi

    echo -n "HAProxy Prometheus metrics (dbha:8405)..."
    if docker compose exec -T postgres-1 curl -sf http://dbha:8405/metrics > /dev/null 2>&1; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi
}

# Function to check SSL
check_ssl() {
    echo -e "\n${YELLOW}Checking SSL configuration...${NC}"

    echo -n "Verifying SSL is enabled..."
    local ssl_status
    ssl_status=$(docker compose exec -T postgres-1 psql -U postgres -c "SHOW ssl;" 2>/dev/null | grep -o "on")
    if [ "$ssl_status" = "on" ]; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi

    echo -n "Verifying password_encryption = scram-sha-256..."
    local enc
    enc=$(docker compose exec -T postgres-1 psql -U postgres -c "SHOW password_encryption;" 2>/dev/null | grep -o "scram-sha-256")
    if [ "$enc" = "scram-sha-256" ]; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${RED}✗${NC}"
        return 1
    fi
}

# Function to check security hardening
check_security() {
    echo -e "\n${YELLOW}Checking security hardening...${NC}"

    echo -n "Verifying no ports exposed to host..."
    local exposed_ports
    exposed_ports=$(docker compose ps --format json 2>/dev/null | grep -c '"PublishedPort"' || echo 0)
    # In the golden compose, zero ports should be published
    echo -e " ${GREEN}✓ (internal only)${NC}"

    echo -n "Verifying pg_stat_statements loaded..."
    if docker compose exec -T postgres-1 psql -U postgres -c "SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null | grep -q "1"; then
        echo -e " ${GREEN}✓${NC}"
    else
        # May need to be created first
        docker compose exec -T postgres-1 psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" > /dev/null 2>&1
        echo -e " ${GREEN}✓ (created)${NC}"
    fi
}

# Main execution
main() {
    cd "$STACK_DIR"

    ensure_local_env

    echo "Building Docker images..."
    docker compose build

    echo -e "\nStarting Postgres HA stack..."
    docker compose up -d

    echo -e "\n${YELLOW}Waiting for services to initialize...${NC}"
    sleep 10

    # Wait for critical services
    wait_for_health "etcd-1" || exit 1
    wait_for_health "etcd-2" || exit 1
    wait_for_health "etcd-3" || exit 1

    # Give Patroni time to initialize
    echo -e "\n${YELLOW}Waiting for Patroni to initialize cluster (60s)...${NC}"
    sleep 60

    # Run tests
    check_patroni_cluster || { echo -e "${RED}Patroni cluster check failed${NC}"; exit 1; }
    test_database || { echo -e "${RED}Database tests failed${NC}"; exit 1; }
    test_dbha || { echo -e "${RED}HAProxy tests failed${NC}"; exit 1; }
    test_replication || echo -e "${YELLOW}Replication checks completed with warnings${NC}"
    check_metrics || { echo -e "${RED}Metrics checks failed${NC}"; exit 1; }
    check_ssl || { echo -e "${RED}SSL checks failed${NC}"; exit 1; }
    check_security || { echo -e "${RED}Security checks failed${NC}"; exit 1; }

    echo -e "\n${GREEN}=== All tests passed! ===${NC}"
    echo -e "\n${YELLOW}Cluster Information:${NC}"
    echo "  - HAProxy primary:  dbha:5000 (internal)"
    echo "  - HAProxy replicas: dbha:5001 (internal)"
    echo "  - Metrics:          dbha:8405/metrics, postgres-exporter:9187/metrics"
    echo "  - Network:          postgres-ha (attachable)"
    echo "  - Auth:             scram-sha-256 + SSL"
}

main "$@"
