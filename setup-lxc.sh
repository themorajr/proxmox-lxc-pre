#!/usr/bin/env bash
# =============================================================================
# setup-lxc.sh
#
# All-in-one post-install script for a freshly created Proxmox LXC container.
# Enables SSH access and installs Docker + Docker Compose.
#
# Usage (run INSIDE the LXC container as root, e.g. via `pct exec <ID> -- bash`
# or by pasting into the container's console):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/themorajr/proxmox-lxc-pre/main/setup-lxc.sh)"
#
# or locally:
#
#   chmod +x setup-lxc.sh
#   ./setup-lxc.sh
#
# Optional environment variables:
#   ROOT_PASSWORD=yourpassword   set/reset the root password (needed if the
#                                 LXC template has no password set yet)
#   ALLOW_ROOT_SSH=yes|no        allow root login over SSH (default: yes)
#   EXTRA_USER=username          non-root user to add to the "docker" group
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors / logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

msg_info()  { echo -e " ${BLUE}INFO${NC}  $1"; }
msg_ok()    { echo -e " ${GREEN}OK${NC}    $1"; }
msg_warn()  { echo -e " ${YELLOW}WARN${NC}  $1"; }
msg_error() { echo -e " ${RED}ERROR${NC} $1"; }

trap 'msg_error "Script failed at line $LINENO. Aborting."' ERR

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  msg_error "Please run this script as root (e.g. inside the LXC console)."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  msg_error "This script only supports Debian/Ubuntu based containers (apt-get not found)."
  exit 1
fi

ALLOW_ROOT_SSH="${ALLOW_ROOT_SSH:-yes}"

# ---------------------------------------------------------------------------
# Network / DNS pre-flight check
# ---------------------------------------------------------------------------
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 8.8.8.8}"

check_network() { timeout 3 bash -c "cat < /dev/null > /dev/tcp/1.1.1.1/443" >/dev/null 2>&1; }
check_dns()     { getent hosts archive.ubuntu.com >/dev/null 2>&1 || getent hosts deb.debian.org >/dev/null 2>&1; }

if ! check_network; then
  msg_error "No outbound network connectivity from inside this container (can't reach 1.1.1.1:443)."
  msg_error "This is a container/host networking issue, not something this script can fix."
  msg_error "On the Proxmox host, check: pct config <CTID> | grep -i net"
  msg_error "and make sure the bridge/gateway/firewall allow outbound traffic."
  exit 1
fi

if ! check_dns; then
  msg_warn "Network is up but DNS resolution is failing."
  msg_info "Trying to fix it by setting temporary nameservers: ${DNS_SERVERS}"
  cp -aL /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
  rm -f /etc/resolv.conf
  { for ns in $DNS_SERVERS; do echo "nameserver ${ns}"; done; } > /etc/resolv.conf

  if check_dns; then
    msg_ok "DNS resolution fixed"
  else
    msg_error "DNS is still failing after setting nameservers to: ${DNS_SERVERS}"
    msg_error "On the Proxmox host, check/set: pct set <CTID> -nameserver 1.1.1.1 -searchdomain local"
    msg_error "then: pct reboot <CTID>"
    exit 1
  fi
fi

msg_info "Updating package lists..."
apt-get update -y >/dev/null
msg_ok "Package lists updated"

msg_info "Installing base packages (curl, sudo, ca-certificates, gnupg)..."
apt-get install -y curl sudo ca-certificates gnupg lsb-release >/dev/null
msg_ok "Base packages installed"

# ---------------------------------------------------------------------------
# 1) SSH setup
# ---------------------------------------------------------------------------
msg_info "Installing OpenSSH server..."
apt-get install -y openssh-server >/dev/null
msg_ok "openssh-server installed"

SSHD_CONFIG="/etc/ssh/sshd_config"

if [[ "$ALLOW_ROOT_SSH" == "yes" ]]; then
  msg_info "Enabling root login over SSH..."
  if grep -qE '^#?PermitRootLogin' "$SSHD_CONFIG"; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
  else
    echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
  fi
  msg_ok "Root login enabled"
else
  msg_info "Leaving root SSH login as-is (ALLOW_ROOT_SSH=no)"
fi

if grep -qE '^#?PasswordAuthentication' "$SSHD_CONFIG"; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
else
  echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
fi

systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
msg_ok "SSH service enabled and running"

if [[ -n "${ROOT_PASSWORD:-}" ]]; then
  msg_info "Setting root password..."
  echo "root:${ROOT_PASSWORD}" | chpasswd
  msg_ok "Root password set"
else
  msg_warn "ROOT_PASSWORD not set — make sure root already has a password or an SSH key, otherwise you can't log in."
fi

# ---------------------------------------------------------------------------
# 2) Docker installation
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  msg_warn "Docker is already installed, skipping installation"
else
  msg_info "Setting up Docker's official apt repository..."
  install -m 0755 -d /etc/apt/keyrings

  . /etc/os-release
  DOCKER_OS_ID="$ID"

  curl -fsSL "https://download.docker.com/linux/${DOCKER_OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_OS_ID} \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  msg_ok "Docker apt repository configured"

  msg_info "Installing Docker Engine + Compose plugin..."
  apt-get update -y >/dev/null
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  msg_ok "Docker installed"
fi

msg_info "Enabling Docker service..."
systemctl enable docker >/dev/null 2>&1 || true
systemctl restart docker
msg_ok "Docker service enabled and running"

# LXC containers usually need nesting=1 and keyctl=1 on the Proxmox host side
# for Docker to run properly. See summary note below.

if [[ -n "${EXTRA_USER:-}" ]]; then
  if id "$EXTRA_USER" >/dev/null 2>&1; then
    msg_info "Adding user '${EXTRA_USER}' to the docker group..."
    usermod -aG docker "$EXTRA_USER"
    msg_ok "User '${EXTRA_USER}' added to docker group (re-login required)"
  else
    msg_warn "User '${EXTRA_USER}' does not exist, skipping group assignment"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
DOCKER_VERSION="$(docker --version 2>/dev/null || echo 'unknown')"

echo
echo -e "${GREEN}=========================================================${NC}"
echo -e "${GREEN} LXC setup complete!${NC}"
echo -e "${GREEN}=========================================================${NC}"
echo -e " SSH:      ssh root@${IP_ADDR:-<container-ip>}"
echo -e " Docker:   ${DOCKER_VERSION}"
echo
msg_warn "This container must have 'nesting=1' (and usually 'keyctl=1')"
msg_warn "enabled on the Proxmox HOST for Docker to work inside an LXC:"
echo -e "   ${BLUE}pct set <CTID> -features nesting=1,keyctl=1${NC}"
echo -e "   (then reboot the container: ${BLUE}pct reboot <CTID>${NC})"
echo
