<#
.SYNOPSIS
  Windows (PowerShell) equivalent of setup.sh - brings up the multi-distro
  patch-management lab (target nodes only, or with -WithAwx).

.EXAMPLE
  ./scripts/setup.ps1
  ./scripts/setup.ps1 -WithAwx

.NOTES
  Requires Docker Desktop (WSL2 backend) with the `docker compose` CLI, and
  OpenSSH client tools (ssh-keygen) - both ship with Windows 10/11 by default.
#>
param(
    [switch]$WithAwx
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$SshKey = Join-Path $HOME ".ssh\id_rsa_ansible"

Write-Host "==> Checking for local SSH key pair..."
if (-not (Test-Path $SshKey)) {
    Write-Host "    No key found at $SshKey, generating one (lab use only)."
    ssh-keygen -t rsa -b 4096 -N '""' -f $SshKey
} else {
    Write-Host "    Found existing key at $SshKey."
}

Write-Host "==> Staging public key into build context..."
Copy-Item "$SshKey.pub" (Join-Path $RepoRoot "id_rsa_ansible.pub") -Force

Write-Host "==> Building and starting fleet nodes (rhel-node, ubuntu-node, debian-node)..."
docker compose up --build -d rhel-node ubuntu-node debian-node

if ($WithAwx) {
    Write-Host "==> Starting AWX control plane (this can take a few minutes on first run)..."
    docker compose --profile awx up -d --build   # --build: awx-receptor image (docker/awx-receptor)
    Write-Host "    AWX web UI will be available at http://localhost:8050 once migrations finish."
    Write-Host "    Tail startup with: docker compose logs -f awx-web"
    Write-Host "    Then provision AWX with: ./scripts/awx-configure.sh (from WSL2/Git Bash)"
}

Write-Host "==> Waiting for SSH to come up on fleet nodes..."
foreach ($port in 2221, 2222, 2223) {
    for ($i = 0; $i -lt 30; $i++) {
        $result = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue
        if ($result.TcpTestSucceeded) { break }
        Start-Sleep -Seconds 1
    }
}

Write-Host "==> Fleet is up. Verify connectivity with:"
Write-Host "    ansible linux_cluster -i ansible/inventory.ini -m ping"
Write-Host "==> Run the patch playbook with:"
Write-Host "    ansible-playbook -i ansible/inventory.ini ansible/patch.yml"
