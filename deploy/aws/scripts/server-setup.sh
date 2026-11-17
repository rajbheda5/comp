#!/usr/bin/env bash
# One-time host setup for Ubuntu 24.04. Runs automatically as Lightsail
# user-data on first boot (as root); safe to re-run by hand with sudo.
#   - Docker Engine + Compose v2 (Ubuntu packages)
#   - 2 GB swap (headroom for a 4 GB box during deploys)
#   - git, for pulling deploy/aws updates

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends docker.io docker-compose-v2 git ca-certificates
systemctl enable --now docker

if id ubuntu >/dev/null 2>&1; then
  usermod -aG docker ubuntu
fi

if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi
sysctl -w vm.swappiness=10
echo 'vm.swappiness=10' >/etc/sysctl.d/99-comp.conf

# Docker log rotation for anything not using the compose logging settings.
mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' >/etc/docker/daemon.json
  systemctl restart docker
fi

mkdir -p /opt/comp
chown ubuntu:ubuntu /opt/comp 2>/dev/null || true
echo "server-setup complete"
