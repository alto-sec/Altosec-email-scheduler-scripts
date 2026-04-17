#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Altosec Email Scheduler — Windows: WSL2 mirrored-networking setup + runner registration.

.DESCRIPTION
  Target app repo: https://github.com/alto-sec/Altosec-email-scheduler
  Public raw: alto-sec/Altosec-email-scheduler-scripts/windows/bootstrap-email-scheduler-runner.ps1
  (also published as bootstrap-new-windows-runner.ps1 for legacy URL compatibility)

  APPROACH — Docker Engine (not Docker Desktop):
  This script runs on Windows and configures WSL2 with "mirrored" networking so that
  when the Linux runner inside WSL2 starts a Docker container with network_mode: host,
  the container shares the actual Windows network interfaces and sees real client IPs.

  After this script runs:
    1. WSL2 is configured for mirrored networking (~/.wslconfig).
    2. A Windows inbound firewall rule is created for the deploy port.
    3. The GitHub Actions runner is registered as a Windows service.

  The runner itself (and Docker Engine) runs INSIDE WSL2 Ubuntu.
  To complete setup, open WSL2 Ubuntu and run:
    sudo bash /mnt/path/scripts/linux/bootstrap-email-scheduler-runner.sh

  Or use the one-liner (see README). The Linux runner appears with "Linux" label on GitHub.
  Use the "Deploy self-hosted Linux" workflow for deployments from Linux / WSL2 runners.

  SHARED HOST (proxy + email on same PC):
  - Runner folder: C:\actions-runner-email-scheduler (proxy uses C:\actions-runner)
  - Deploy folder: C:\altosec-deploy-email (proxy uses C:\altosec-deploy)
  - System var: ALTOSEC_EMAIL_DEPLOY_DIR only (never ALTOSEC_DEPLOY_DIR — proxy owns that)
  - ALTOSEC_DEPLOY_DOMAIN: proxy-only; this script never sets or clears it
  - Email TLS (-Tls): ALTOSEC_EMAIL_DEPLOY_DOMAIN only

.PARAMETER Tls
  공개 FQDN + Let's Encrypt(ACME) 배포 경로. 없으면 HTTP-only(도메인 설정 없음).

.PARAMETER HttpOnly
  명시적으로 HTTP-only (기본과 동일; 스크립트에서 -Tls 를 끔).

.PARAMETER DeployDomainFqdn
  -Tls 일 때만 사용. 공개 FQDN(Machine: ALTOSEC_EMAIL_DEPLOY_DOMAIN). ALTOSEC_DEPLOY_DOMAIN(프록시)과 별개.

.PARAMETER RunnerName
  러너 고유 이름.

.PARAMETER RegistrationToken
  GitHub 등록 토큰 (이 레포 Settings → Actions → Runners → New).

.PARAMETER RepoUrl
  기본 https://github.com/alto-sec/Altosec-email-scheduler

.PARAMETER RunnerRoot
  기본 C:\actions-runner-email-scheduler

.PARAMETER DeployDir
  기본 C:\altosec-deploy-email

.PARAMETER AcmeContactEmail
  -Tls 일 때 Let's Encrypt 연락처. 배포 폴더의 acme-contact-email.txt 로만 저장.
#>
[CmdletBinding()]
param(
    [string] $DeployDomainFqdn = '',
    [string] $RunnerName = '',
    [string] $RegistrationToken = '',
    [string] $RepoUrl = '',
    [string] $RunnerRoot = '',
    [string] $DeployDir = '',
    [string] $AcmeContactEmail = '',
    [switch] $Tls,
    [switch] $HttpOnly
)

$ErrorActionPreference = 'Stop'

$useTls = $false
if ($Tls) { $useTls = $true }
if ($HttpOnly) { $useTls = $false }
if ($env:ALTOSEC_BOOTSTRAP_TLS -match '^(1|true|yes|on)$') { $useTls = $true }
if ($env:ALTOSEC_BOOTSTRAP_HTTP_ONLY -match '^(1|true|yes|on)$') { $useTls = $false }

function Read-WithDefault {
    param(
        [string] $Prompt,
        [string] $Default
    )
    $hint = if ($null -ne $Default -and $Default -ne '') { " [$Default]" } else { '' }
    $line = Read-Host "$Prompt$hint"
    if ([string]::IsNullOrWhiteSpace($line)) { return $Default }
    return $line.Trim()
}

if ($useTls -and [string]::IsNullOrWhiteSpace($DeployDomainFqdn)) {
    $DeployDomainFqdn = Read-Host 'Public FQDN for email TLS only (Machine: ALTOSEC_EMAIL_DEPLOY_DOMAIN; does not touch proxy ALTOSEC_DEPLOY_DOMAIN)'
}
if ([string]::IsNullOrWhiteSpace($RunnerName)) {
    $RunnerName = Read-Host 'Runner name (unique on GitHub)'
}
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
    $RegistrationToken = Read-Host 'Registration token (GitHub -> New self-hosted runner)'
}

if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    $RepoUrl = Read-WithDefault -Prompt 'Runner repo URL' -Default 'https://github.com/alto-sec/Altosec-email-scheduler'
}
if ([string]::IsNullOrWhiteSpace($RunnerRoot)) {
    $RunnerRoot = Read-WithDefault -Prompt 'Runner install folder' -Default 'C:\actions-runner-email-scheduler'
}
if ([string]::IsNullOrWhiteSpace($DeployDir)) {
    $DeployDir = Read-WithDefault -Prompt 'Deploy extract folder (ALTOSEC_EMAIL_DEPLOY_DIR; not ALTOSEC_DEPLOY_DIR — that is for proxy)' -Default 'C:\altosec-deploy-email'
}
if ($useTls -and [string]::IsNullOrWhiteSpace($AcmeContactEmail)) {
    $AcmeContactEmail = Read-WithDefault -Prompt "Let's Encrypt ACME contact email (saved to deploy folder only, not system env)" -Default 'altosecteam@gmail.com'
}

if ($useTls) {
    if ([string]::IsNullOrWhiteSpace($DeployDomainFqdn)) { throw 'FQDN is required for -Tls (default is HTTP-only / no domain).' }
    $AcmeContactEmail = $AcmeContactEmail.Trim()
    if ([string]::IsNullOrWhiteSpace($AcmeContactEmail)) { throw 'ACME contact email is required for TLS deploy.' }
    if ($AcmeContactEmail -match '(?i)@example\.(com|org|net)$') {
        throw "Let's Encrypt rejects @example.com / .org / .net for ACME contacts. Use a real mailbox."
    }
}
if ([string]::IsNullOrWhiteSpace($RunnerName)) { throw 'Runner name is required.' }
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) { throw 'Registration token is required.' }
$RunnerName = $RunnerName.Trim()

# ── WSL2 mirrored networking ──────────────────────────────────────────────────
# Docker Engine runs inside WSL2 Ubuntu. With networkingMode=mirrored the WSL2
# VM shares Windows' network adapters, so Docker containers using network_mode: host
# bind directly to the Windows NIC and see real inbound client IPs (no NAT).
# This is the WSL2-native replacement for Docker Desktop's "mirrored" setting.
$WslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
$MirroredSection = "[wsl2]`nnetworkingMode=mirrored`n"
if (Test-Path $WslConfigPath) {
    $existing = Get-Content $WslConfigPath -Raw -ErrorAction SilentlyContinue
    if ($existing -notmatch 'networkingMode\s*=\s*mirrored') {
        if ($existing -match '\[wsl2\]') {
            # Inject into existing [wsl2] block
            (Get-Content $WslConfigPath) | ForEach-Object {
                $_
                if ($_ -match '^\[wsl2\]') { 'networkingMode=mirrored' }
            } | Set-Content $WslConfigPath
        } else {
            Add-Content $WslConfigPath "`n[wsl2]`nnetworkingMode=mirrored"
        }
        Write-Host "Added networkingMode=mirrored to $WslConfigPath."
        Write-Host "IMPORTANT: run 'wsl --shutdown' and restart WSL2 for this to take effect."
    } else {
        Write-Host "WSL2 mirrored networking already configured in $WslConfigPath."
    }
} else {
    [System.IO.File]::WriteAllText($WslConfigPath, $MirroredSection, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Created $WslConfigPath with networkingMode=mirrored."
    Write-Host "IMPORTANT: run 'wsl --shutdown' and restart WSL2 for this to take effect."
}

# Docker Engine availability check (must be installed inside WSL2 Ubuntu)
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Warning @"
Docker CLI not found in Windows PATH.
This is expected if Docker Engine runs inside WSL2 (not Docker Desktop).
Complete Docker Engine setup by running inside WSL2 Ubuntu:
  sudo bash scripts/linux/bootstrap-email-scheduler-runner.sh
"@
}

# Email-only Machine var so the same PC can run proxy (ALTOSEC_DEPLOY_DIR -> C:\altosec-deploy) without collisions.
[Environment]::SetEnvironmentVariable('ALTOSEC_EMAIL_DEPLOY_DIR', $DeployDir.Trim(), 'Machine')
if (-not $useTls) {
    [Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_HTTP_ONLY', 'true', 'Machine')
    # Do not clear ALTOSEC_DEPLOY_DOMAIN — that is the proxy stack's Machine var on shared hosts.
    Write-Host "Machine env: ALTOSEC_DEPLOY_HTTP_ONLY=true ALTOSEC_EMAIL_DEPLOY_DIR=$($DeployDir.Trim()) (HTTP / IP — left proxy ALTOSEC_DEPLOY_DOMAIN unchanged)"
} else {
    [Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_HTTP_ONLY', '', 'Machine')
    [Environment]::SetEnvironmentVariable('ALTOSEC_EMAIL_DEPLOY_DOMAIN', $DeployDomainFqdn.Trim(), 'Machine')
    Write-Host "Machine env: ALTOSEC_EMAIL_DEPLOY_DOMAIN=$($DeployDomainFqdn.Trim()) ALTOSEC_EMAIL_DEPLOY_DIR=$($DeployDir.Trim()) (-Tls email only; proxy uses ALTOSEC_DEPLOY_DOMAIN)"
}

$deployRoot = $DeployDir.Trim()
[void][System.IO.Directory]::CreateDirectory($deployRoot)
if ($useTls) {
    $acmePath = Join-Path $deployRoot 'acme-contact-email.txt'
    [System.IO.File]::WriteAllText($acmePath, $AcmeContactEmail, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote ACME contact for Deploy workflow: $acmePath (not stored in system environment variables)."
}

# docker-users group is Docker Desktop-specific — not needed with Docker Engine.

if ($useTls) {
    $fw80 = 'AltosecEmailSchedulerACME80'
    if (-not (Get-NetFirewallRule -Name $fw80 -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $fw80 -DisplayName 'Altosec Email Scheduler ACME HTTP-01 (TCP 80 inbound)' `
            -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -Profile Any | Out-Null
        Write-Host "Created firewall rule $fw80 (TCP 80)."
    }
    $fw443 = 'AltosecEmailSchedulerHTTPS443'
    if (-not (Get-NetFirewallRule -Name $fw443 -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $fw443 -DisplayName 'Altosec Email Scheduler HTTPS (TCP 443 inbound)' `
            -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow -Profile Any | Out-Null
        Write-Host "Created firewall rule $fw443 (TCP 443)."
    }
} else {
    $fw2026 = 'AltosecEmailSchedulerHTTP2026'
    if (-not (Get-NetFirewallRule -Name $fw2026 -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $fw2026 -DisplayName 'Altosec Email Scheduler API (TCP 2026 inbound)' `
            -Direction Inbound -Protocol TCP -LocalPort 2026 -Action Allow -Profile Any | Out-Null
        Write-Host "Created firewall rule $fw2026 (TCP 2026)."
    }
}

if (-not (Test-Path (Join-Path $RunnerRoot 'config.cmd'))) {
    New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' `
        -Headers @{ 'User-Agent' = 'Altosec-EmailScheduler-RunnerBootstrap' }
    $asset = $rel.assets | Where-Object { $_.name -match '^actions-runner-win-x64-[\d.]+\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not find actions-runner-win-x64 zip in latest release.' }
    $zip = Join-Path $env:TEMP $asset.name
    Write-Host "Downloading $($asset.name) ..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $RunnerRoot -Force
    Remove-Item $zip -Force
}

Push-Location $RunnerRoot
if (-not (Test-Path '.\.runner')) {
    $cfg = Join-Path $RunnerRoot 'config.cmd'
    # Unique label = runner name so Deploy matrix jobs pin to this host (runs-on includes matrix.runner_name).
    $labelList = "self-hosted,Windows,altosec-proxy-node,$RunnerName"
    $proc = Start-Process -FilePath $cfg -WorkingDirectory $RunnerRoot -ArgumentList @(
        '--url', $RepoUrl,
        '--token', $RegistrationToken,
        '--name', $RunnerName,
        '--labels', $labelList,
        '--unattended',
        '--runasservice'
    ) -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "config.cmd failed with exit $($proc.ExitCode)" }
    Write-Host 'Runner registered as service.'
} else {
    Write-Host 'Runner already configured (.runner exists). Skipping config.cmd.'
}
Pop-Location

Get-CimInstance Win32_Service -Filter "Name LIKE 'actions.runner%'" | ForEach-Object {
    & sc.exe config $_.Name obj= LocalSystem | Out-Null
    Write-Host "Set $($_.Name) logon to Local System."
}

Get-Service 'actions.runner*' | Restart-Service
Write-Host 'Done. Confirm Idle under GitHub → Altosec-email-scheduler → Runners, then run the Deploy workflow.'
