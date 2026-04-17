#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Altosec Email Scheduler — Windows: WSL2 mirrored networking + firewall setup.

.DESCRIPTION
  This script does three things on the Windows side:
    1. Writes networkingMode=mirrored to %USERPROFILE%\.wslconfig so that Docker
       containers using network_mode: host inside WSL2 bind to the real Windows
       network adapters and see real client IPs (no NAT).
    2. Opens a Windows Firewall inbound rule for TCP 2026.
    3. Sets the Machine environment variable ALTOSEC_EMAIL_DEPLOY_DIR.

  The GitHub Actions runner and Docker Engine are installed INSIDE WSL2 Ubuntu,
  not on Windows. After this script finishes, run inside WSL2 Ubuntu:

    wsl --shutdown   (restart WSL2 so mirrored networking takes effect)
    wsl -d Ubuntu
    curl -fsSL https://raw.githubusercontent.com/alto-sec/Altosec-email-scheduler-scripts/main/linux/bootstrap-email-scheduler-runner.sh | sudo bash

.PARAMETER DeployDir
  Windows-side path that maps to the WSL2 deploy directory.
  Stored as Machine env ALTOSEC_EMAIL_DEPLOY_DIR so the Deploy workflow can find it.
  Default: C:\altosec-deploy-email
#>
[CmdletBinding()]
param(
    [string] $DeployDir = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DeployDir)) {
    $hint = ' [C:\altosec-deploy-email]'
    $line = Read-Host "Deploy directory (ALTOSEC_EMAIL_DEPLOY_DIR)$hint"
    $DeployDir = if ([string]::IsNullOrWhiteSpace($line)) { 'C:\altosec-deploy-email' } else { $line.Trim() }
}

# ── 1. WSL2 mirrored networking ───────────────────────────────────────────────
$WslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $WslConfigPath) {
    $existing = Get-Content $WslConfigPath -Raw -ErrorAction SilentlyContinue
    if ($existing -notmatch 'networkingMode\s*=\s*mirrored') {
        if ($existing -match '\[wsl2\]') {
            (Get-Content $WslConfigPath) | ForEach-Object {
                $_
                if ($_ -match '^\[wsl2\]') { 'networkingMode=mirrored' }
            } | Set-Content $WslConfigPath
        } else {
            Add-Content $WslConfigPath "`n[wsl2]`nnetworkingMode=mirrored"
        }
        Write-Host "Added networkingMode=mirrored to $WslConfigPath."
    } else {
        Write-Host "WSL2 mirrored networking already set in $WslConfigPath."
    }
} else {
    [System.IO.File]::WriteAllText(
        $WslConfigPath,
        "[wsl2]`nnetworkingMode=mirrored`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "Created $WslConfigPath with networkingMode=mirrored."
}

# ── 2. Windows Firewall — TCP 2026 inbound ────────────────────────────────────
$fw = 'AltosecEmailSchedulerHTTP2026'
if (-not (Get-NetFirewallRule -Name $fw -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $fw `
        -DisplayName 'Altosec Email Scheduler API (TCP 2026 inbound)' `
        -Direction Inbound -Protocol TCP -LocalPort 2026 -Action Allow -Profile Any | Out-Null
    Write-Host "Created firewall rule $fw (TCP 2026)."
} else {
    Write-Host "Firewall rule $fw already exists."
}

# ── 3. Machine environment variable ──────────────────────────────────────────
[Environment]::SetEnvironmentVariable('ALTOSEC_EMAIL_DEPLOY_DIR', $DeployDir.Trim(), 'Machine')
[Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_HTTP_ONLY', 'true', 'Machine')
Write-Host "Machine env: ALTOSEC_EMAIL_DEPLOY_DIR=$($DeployDir.Trim())  ALTOSEC_DEPLOY_HTTP_ONLY=true"

# ── Done ─────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host 'Windows-side setup complete. Next steps:'
Write-Host '  1. wsl --shutdown          (apply mirrored networking)'
Write-Host '  2. wsl -d Ubuntu           (open WSL2 Ubuntu)'
Write-Host '  3. curl -fsSL https://raw.githubusercontent.com/alto-sec/Altosec-email-scheduler-scripts/main/linux/bootstrap-email-scheduler-runner.sh | sudo bash'
