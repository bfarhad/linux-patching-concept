<#
.SYNOPSIS
  Windows (PowerShell) equivalent of awx-run-now.sh - manually launches the
  "Weekly Enterprise Linux Patching" job template right now, regardless of
  its schedule. Set $env:LIMIT (e.g. "debian-node") to patch a single node.

  The first run pulls the execution environment image (~1.5 GB) inside
  awx-receptor, so it sits in "running" for a few minutes before any output.
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

$Body = if ($env:LIMIT) { @{ limit = $env:LIMIT } | ConvertTo-Json } else { "{}" }
$Job = Invoke-RestMethod -Headers $Headers -Method Post -ContentType "application/json" -Body $Body -Uri "$AwxUrl/api/v2/job_templates/$JtId/launch/"
Write-Host "==> Launched job: $AwxUrl$($Job.url)"
Write-Host "==> Watch it in the UI: Views -> Jobs. The JSON patch report is on the job's Artifacts tab."
