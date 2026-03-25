import pytest
import httpx
import time
from python_on_whales import DockerClient

API_URL = "http://127.0.0.1:8000"

@pytest.fixture(scope="module")
def docker_stack():
    docker = DockerClient(compose_files=[
        "stacks/edge-router/compose.yaml",
        "stacks/edge-router/tests/e2e/compose.test.yaml"
    ])

    print("Building images...")
    # Ensure images are built.
    # Note: 'docker build' command acts on the compose project services if using 'docker compose build'
    # But here we use docker.build which is for a single image, OR docker.compose.build.
    # User's run script uses `docker compose up --build`.
    # Let's use docker.compose.build()
    docker.compose.build(["valkey", "edge-router-api", "cert-manager"])

    print("Starting Phase 2 Stack...")
    docker.compose.up(["valkey", "edge-router-api", "cert-manager"], detach=True)

    # Wait for startup
    time.sleep(10)

    yield docker

    print("Tearing down...")
    docker.compose.down(volumes=True)

def test_cert_manager_integration(docker_stack):
    """
    Test that adding a domain triggers the Cert Manager service.
    """
    domain = "phase2-test.example.com"

    # 1. API Call
    print(f"Adding domain {domain} via API...")
    try:
        with httpx.Client() as client:
            resp = client.post(f"{API_URL}/domains", json={"domain": domain})
            assert resp.status_code == 200
            assert resp.json()["domain"] == domain
    except httpx.ConnectError:
        pytest.fail("Could not connect to Edge API. Is it running?")

    # 2. Monitor Logs
    print("Waiting for Cert Manager to pick up the domain (checking logs)...")
    found_attempt = False

    # Poll logs for 20 seconds
    for i in range(10):
        logs = docker_stack.compose.logs(services=["cert-manager"])
        # Matches "Attempting to issue/renew certificate for ..."
        if f"Attempting to issue/renew certificate for {domain}" in logs:
            found_attempt = True
            break
        print(f"Waiting... ({i+1}/10)")
        time.sleep(2)

    if not found_attempt:
        print("DEBUG: Cert Manager Logs:")
        print(docker_stack.compose.logs(services=["cert-manager"]))

    assert found_attempt, "Cert Manager did not log an attempt to issue certificate"

    # 3. Verify Failure (Fast Fail Expectation)
    # Since we used dummy credentials for Route53/Generic, we expect a failure log.
    final_logs = docker_stack.compose.logs(services=["cert-manager"])
    # "Lego failed for ..." or "Failed to issue certificate"
    # Our code: logger.error(f"Lego failed for {domain}: ...")
    assert "Lego failed for" in final_logs, "Expected cert issuance to fail (dry run verification)"
