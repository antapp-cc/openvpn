#!/usr/bin/env bash
set -e

. /etc/os-release

case "${VERSION_CODENAME:-}" in
  bullseye|bookworm|trixie)
    codename="${VERSION_CODENAME}"
    ;;
  *)
    echo "不支持的 Debian 版本: ${PRETTY_NAME:-unknown}" >&2
    exit 1
    ;;
esac

cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware
EOF

apt-get clean
apt-get update -y
