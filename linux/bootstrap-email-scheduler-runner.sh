#!/usr/bin/env bash
# Altosec Email Scheduler — Linux / WSL2 runner bootstrap.
#
# Works on bare-metal Ubuntu/Debian AND inside WSL2 Ubuntu.
# Idempotent: each step checks whether the component is already present and
# skips installation if so. Safe to run again after partial failure.
#
# What this script does:
#   1. Install Docker Engine (skipped if already present)
#   2. Set system environment variables in /etc/environment (idempotent)
#   3. Open firewall ports via ufw (idempotent)
#   4. Download and configure a GitHub Actions self-hosted runner (skipped if .runner exists)
#   5. Install and start the runner as a systemd service (or init.d fallback)
#
# Requirements:
#   - Ubuntu 20.04+ or Debian 11+ (bare-metal or WSL2)
#   - Run as root: sudo bash bootstrap-email-scheduler-runner.sh [options]
#   - Internet access for Docker / runner downloads
#
# On Windows: run this script INSIDE WSL2 Ubuntu. Configure WSL2 mirrored
# networking first (scripts/windows/setup-wsl2-docker.ps1) so that
# network_mode: host in Docker sees real client IPs.
#
# Usage:
#   sudo bash bootstrap-email-scheduler-runner.sh [--tls] [--http-only]
#   ALTOSEC_BOOTSTRAP_TLS=1 sudo bash bootstrap-email-scheduler-runner.sh
#
# Parameters (all can be passed as env vars):
#   --tls             Enable TLS / Let's Encrypt path (prompts for FQDN)
#   --http-only       HTTP-only mode (default; no domain or ACME)
#   RUNNER_NAME       Runner name (unique on GitHub)
#   REGISTRATION_TOKEN  GitHub registration token
#   DEPLOY_DOMAIN_FQDN  Public FQDN (--tls only)
#   ACME_CONTACT_EMAIL  Let's Encrypt contact email
#   RUNNER_ROOT       Runner install path (default /opt/actions-runner-email-scheduler)
#   ALTOSEC_EMAIL_DEPLOY_DIR  Deploy directory (default /opt/altosec-deploy-email)
#   REPO_URL          GitHub repo URL (default https://github.com/alto-sec/Altosec-email-scheduler)

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 $*"
}

is_wsl() {
  grep -qi "microsoft" /proc/version 2>/dev/null
}

# ── parse flags ───────────────────────────────────────────────────────────────
USE_TLS=false
for arg in "$@"; do
  case "$arg" in
    --tls)       USE_TLS=true ;;
    --http-only) USE_TLS=false ;;
  esac
done
[[ "${ALTOSEC_BOOTSTRAP_TLS:-}"       =~ ^(1|true|yes|on)$  ]] && USE_TLS=true
[[ "${ALTOSEC_BOOTSTRAP_HTTP_ONLY:-}" =~ ^(1|true|yes|on)$  ]] && USE_TLS=false

require_root

# ── defaults ──────────────────────────────────────────────────────────────────
RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runner-email-scheduler}"
DEPLOY_DIR="${ALTOSEC_EMAIL_DEPLOY_DIR:-/opt/altosec-deploy-email}"
REPO_URL="${REPO_URL:-https://github.com/alto-sec/Altosec-email-scheduler}"
RUNNER_SVC_USER="runner-svc"

# ── interactive prompts ───────────────────────────────────────────────────────
# Always read from /dev/tty so prompts work even when stdin is a pipe
# (e.g. curl ... | sudo bash).
read_val() {
  local var="$1" prompt="$2" default="${3:-}" val
  if [[ -n "${!var:-}" ]]; then return; fi
  local hint=""; [[ -n "$default" ]] && hint=" [$default]"
  read -rp "$prompt$hint: " val </dev/tty
  printf -v "$var" '%s' "${val:-$default}"
}

if $USE_TLS; then
  read_val DEPLOY_DOMAIN_FQDN "Public FQDN for email TLS (ALTOSEC_EMAIL_DEPLOY_DOMAIN)" ""
  read_val ACME_CONTACT_EMAIL "Let's Encrypt ACME contact email" "altosecteam@gmail.com"
fi
read_val RUNNER_NAME           "Runner name (unique on GitHub)" ""
read_val REGISTRATION_TOKEN    "Registration token (GitHub -> New self-hosted runner)" ""

# ── validation ────────────────────────────────────────────────────────────────
RUNNER_NAME="${RUNNER_NAME//[[:space:]]/}"
REGISTRATION_TOKEN="${REGISTRATION_TOKEN//[[:space:]]/}"
[[ -z "$RUNNER_NAME" ]]         && die "Runner name is required."
[[ -z "$REGISTRATION_TOKEN" ]]  && die "Registration token is required."
if $USE_TLS; then
  [[ -z "${DEPLOY_DOMAIN_FQDN:-}" ]] && die "FQDN is required for --tls."
  [[ "${ACME_CONTACT_EMAIL:-}" =~ @example\.(com|org|net)$ ]] \
    && die "Use a real ACME contact email (not @example.com/org/net)."
fi

info "=== Altosec Email Scheduler bootstrap ==="
info "Mode:       $(if $USE_TLS; then echo 'TLS'; else echo 'HTTP-only'; fi)"
info "Runner:     $RUNNER_NAME  →  $RUNNER_ROOT"
info "Deploy dir: $DEPLOY_DIR"
is_wsl && info "Environment: WSL2 detected"

# ── Step 1: Docker Engine ─────────────────────────────────────────────────────
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  info "Docker Engine already installed ($(docker --version 2>/dev/null | head -1)). Skipping."
else
  info "Installing Docker Engine (apt)..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  DISTRO_ID="$(. /etc/os-release && echo "${ID}")"
  DISTRO_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-$(lsb_release -cs)}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DISTRO_ID} ${DISTRO_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  info "Docker Engine installed and enabled."
fi

# ── Step 2: Service user ──────────────────────────────────────────────────────
if ! id -u "$RUNNER_SVC_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$RUNNER_SVC_USER"
  info "Created user $RUNNER_SVC_USER."
fi
# Add to docker group (idempotent)
usermod -aG docker "$RUNNER_SVC_USER"

# ── Step 3: Environment variables ────────────────────────────────────────────
# Persist in /etc/environment (read by PAM / systemd EnvironmentFile)
set_sys_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" /etc/environment 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" /etc/environment
  else
    echo "${key}=${value}" >> /etc/environment
  fi
  export "${key}=${value}"
}
remove_sys_env() {
  sed -i "/^${1}=/d" /etc/environment 2>/dev/null || true
}

mkdir -p "$DEPLOY_DIR"
chown "$RUNNER_SVC_USER:$RUNNER_SVC_USER" "$DEPLOY_DIR"

set_sys_env "ALTOSEC_EMAIL_DEPLOY_DIR" "$DEPLOY_DIR"

if ! $USE_TLS; then
  set_sys_env "ALTOSEC_DEPLOY_HTTP_ONLY" "true"
  # Do not touch ALTOSEC_DEPLOY_DOMAIN — that belongs to proxy server on shared hosts.
  info "Env: ALTOSEC_DEPLOY_HTTP_ONLY=true  ALTOSEC_EMAIL_DEPLOY_DIR=$DEPLOY_DIR  (HTTP / IP)"
else
  remove_sys_env "ALTOSEC_DEPLOY_HTTP_ONLY"
  DEPLOY_DOMAIN_FQDN="${DEPLOY_DOMAIN_FQDN,,}"
  set_sys_env "ALTOSEC_EMAIL_DEPLOY_DOMAIN" "$DEPLOY_DOMAIN_FQDN"
  info "Env: ALTOSEC_EMAIL_DEPLOY_DOMAIN=$DEPLOY_DOMAIN_FQDN  ALTOSEC_EMAIL_DEPLOY_DIR=$DEPLOY_DIR  (TLS)"

  ACME_CONTACT_EMAIL="${ACME_CONTACT_EMAIL:-altosecteam@gmail.com}"
  echo "$ACME_CONTACT_EMAIL" > "$DEPLOY_DIR/acme-contact-email.txt"
  chown "$RUNNER_SVC_USER:$RUNNER_SVC_USER" "$DEPLOY_DIR/acme-contact-email.txt"
  info "Wrote ACME contact: $DEPLOY_DIR/acme-contact-email.txt"
fi

# ── Step 4: Firewall (ufw) ─────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
  if $USE_TLS; then
    ufw allow 80/tcp  comment 'Altosec Email Scheduler ACME HTTP-01' 2>/dev/null || true
    ufw allow 443/tcp comment 'Altosec Email Scheduler HTTPS'        2>/dev/null || true
    info "UFW: opened TCP 80 (ACME), 443 (HTTPS)."
  else
    ufw allow 2026/tcp comment 'Altosec Email Scheduler API' 2>/dev/null || true
    info "UFW: opened TCP 2026 (HTTP API)."
  fi
else
  PORTS=$(if $USE_TLS; then echo "TCP 80, 443"; else echo "TCP 2026"; fi)
  warn "ufw not found — ensure your firewall / cloud security group allows $PORTS inbound."
fi

# ── Step 5: GitHub Actions runner ────────────────────────────────────────────
mkdir -p "$RUNNER_ROOT"

if [[ -f "$RUNNER_ROOT/.runner" ]]; then
  info "Runner already configured ($RUNNER_ROOT/.runner exists). Skipping download and config."
else
  info "Downloading latest GitHub Actions runner (linux-x64)..."
  RUNNER_REL="$(curl -fsSL \
    -H 'User-Agent: Altosec-EmailScheduler-RunnerBootstrap' \
    https://api.github.com/repos/actions/runner/releases/latest)"

  RUNNER_URL="$(echo "$RUNNER_REL" | python3 -c "
import sys, json
rel = json.load(sys.stdin)
asset = next(
  (a for a in rel['assets']
   if 'linux-x64' in a['name'] and a['name'].endswith('.tar.gz')),
  None)
print(asset['browser_download_url'] if asset else '')
")"
  [[ -z "$RUNNER_URL" ]] && die "Could not find linux-x64 runner tar.gz in latest release."

  RUNNER_TAR="/tmp/actions-runner-linux.tar.gz"
  info "Downloading: $RUNNER_URL"
  curl -fsSL -o "$RUNNER_TAR" "$RUNNER_URL"
  tar -xzf "$RUNNER_TAR" -C "$RUNNER_ROOT"
  rm -f "$RUNNER_TAR"

  chown -R "$RUNNER_SVC_USER:$RUNNER_SVC_USER" "$RUNNER_ROOT"

  LABEL_LIST="self-hosted,Linux,altosec-proxy-node,$RUNNER_NAME"
  info "Configuring runner  name=$RUNNER_NAME  labels=$LABEL_LIST"

  sudo -u "$RUNNER_SVC_USER" "$RUNNER_ROOT/config.sh" \
    --url "$REPO_URL" \
    --token "$REGISTRATION_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABEL_LIST" \
    --unattended \
    --replace
  info "Runner configured."
fi

# ── Step 6: Runner service (systemd or init.d) ────────────────────────────────
SVC_FILE_MARKER="$RUNNER_ROOT/.service"

if [[ -f "$SVC_FILE_MARKER" ]]; then
  SVC_NAME="$(cat "$SVC_FILE_MARKER")"
  if command -v systemctl &>/dev/null \
     && systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; then
    info "Runner service '$SVC_NAME' already active. Skipping."
  else
    info "Starting runner service '$SVC_NAME'..."
    "$RUNNER_ROOT/svc.sh" start || true
  fi
else
  info "Installing runner as system service..."
  # svc.sh must be run from the runner directory
  pushd "$RUNNER_ROOT" >/dev/null
  ./svc.sh install "$RUNNER_SVC_USER"
  ./svc.sh start
  popd >/dev/null
  info "Runner service installed and started."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
SVC_STATUS="unknown"
if [[ -f "$SVC_FILE_MARKER" ]]; then
  SVC_NAME="$(cat "$SVC_FILE_MARKER")"
  if command -v systemctl &>/dev/null 2>/dev/null; then
    SVC_STATUS="$(systemctl is-active "$SVC_NAME" 2>/dev/null || echo 'unknown')"
  fi
fi

info "=== Bootstrap complete ==="
info "Runner service status: $SVC_STATUS"
info "Next: verify runner shows Idle in GitHub → Altosec-email-scheduler → Settings → Runners"
info "Then: trigger the Deploy workflow (Actions → Deploy self-hosted Linux)."
