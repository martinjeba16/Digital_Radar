#!/usr/bin/env bash
# Bootstrap an Ubuntu EC2 instance for Digital Radar.
# Usage: sudo ./deploy/ec2/setup.sh
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  docker.io \
  docker-compose-plugin \
  nginx \
  certbot \
  python3-certbot-nginx \
  git \
  curl \
  ufw

systemctl enable docker
systemctl start docker

# Firewall: SSH + HTTP/S only
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo ""
echo "EC2 bootstrap complete."
echo "Next steps:"
echo "  1. Clone/copy the repo to this server"
echo "  2. cp backend/.env.example backend/.env && edit for production"
echo "     (set GROQ_API_KEY from https://console.groq.com/keys)"
echo "  3. Add firebase-service-account.json to backend/"
echo "  4. docker compose up -d --build"
echo "  5. Configure nginx: deploy/nginx/digital-radar.conf + certbot"
echo ""
echo "See docs/DEPLOYMENT.md for the full guide."
