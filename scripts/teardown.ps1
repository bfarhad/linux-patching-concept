<#
.SYNOPSIS
  Windows (PowerShell) equivalent of teardown.sh.

.EXAMPLE
  ./scripts/teardown.ps1
  ./scripts/teardown.ps1 -Volumes   # also wipes AWX's postgres/projects data
#>
param(
    [switch]$Volumes
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

if ($Volumes) {
    docker compose --profile awx down -v
} else {
    docker compose --profile awx down
}

Remove-Item -Path (Join-Path $RepoRoot "id_rsa_ansible.pub") -ErrorAction SilentlyContinue
Write-Host "==> Lab stopped."
