<#
.SYNOPSIS
  Windows (PowerShell) equivalent of awx-run-now.sh - manually launches the
  "Weekly Enterprise Linux Patching" job template right now, regardless of
  its schedule.

  NOTE: in this standalone docker-compose AWX the job is created but fails at
  start with "no Execution Environment could be found" (no podman runtime;
  see README "Known limitation"). Patch the fleet via ansible-playbook instead.
#>
$ErrorActionPreference = "Stop"

$AwxUrl  = if ($env:AWX_URL) { $env:AWX_URL } else { "http://localhost:8050" }
$AwxUser = if ($env:AWX_ADMIN_USER) { $env:AWX_ADMIN_USER } else { "admin" }
$AwxPass = if ($env:AWX_ADMIN_PASSWORD) { $env:AWX_ADMIN_PASSWORD } else { "adminpassword" }

$Cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${AwxUser}:${AwxPass}"))
$Headers = @{ Authorization = "Basic $Cred" }

$Jt = Invoke-RestMethod -Headers $Headers -Uri "$AwxUrl/api/v2/job_templates/?name=Weekly%20Enterprise%20Linux%20Patching"
if ($Jt.results.Count -eq 0) {
    Write-Error "Job template 'Weekly Enterprise Linux Patching' not found. Run scripts/awx-configure.sh (from WSL/Git Bash) first."
    exit 1
}
$JtId = $Jt.results[0].id

$Job = Invoke-RestMethod -Headers $Headers -Method Post -Uri "$AwxUrl/api/v2/job_templates/$JtId/launch/"
Write-Host "==> Launched job: $AwxUrl$($Job.url)"
Write-Host "==> Expect it to fail with 'no Execution Environment could be found' (known limitation, see README)."
Write-Host "    To actually patch the fleet (from WSL2): ansible-playbook -i ansible/inventory.ini ansible/patch.yml"
