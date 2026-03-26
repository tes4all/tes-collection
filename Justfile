# Justfile for monorepo management

# Update all python projects using uv
update-all:
    @python3 scripts/update_deps.py cli --type cli
    @python3 scripts/update_deps.py images/cert-manager --type image
    @python3 scripts/update_deps.py images/cert-syncer --type image
    @python3 scripts/update_deps.py images/edge-router-api --type image
    @python3 scripts/update_deps.py stacks/edge-router/tests/e2e --type venv

# Update Docker images
update-images:
    @uv run --with requests --with packaging python3 scripts/update_docker_images.py .

# Update Terraform provider lock files
update-terraform:
    @echo "==> Updating Terraform provider locks..."
    cd infrastructure/terraform/modules/tes-infra && tofu init -upgrade -backend=false
    @echo "==> Provider lock files updated."

# Terraform Proxmox Module Local Testing (using OpenTofu)
test-tf-proxmox:
    @echo "==> Initializing OpenTofu..."
    cd infrastructure/terraform/local_test && tofu init
    @echo "==> Applying test configuration..."
    cd infrastructure/terraform/local_test && tofu apply -auto-approve

# Destroy the Terraform Local Test (using OpenTofu)
destroy-tf-proxmox:
    @echo "==> Destroying test infrastructure..."
    cd infrastructure/terraform/local_test && tofu destroy -auto-approve
