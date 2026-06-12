#!/usr/bin/env bash
set -e

. /etc/os-release

case "${VERSION_CODENAME:-}" in
  bullseye)
    codename="bullseye"
    components="main contrib non-free"
    ;;
  bookworm|trixie)
    codename="${VERSION_CODENAME}"
    components="main contrib non-free non-free-firmware"
    ;;
  *)
    echo "不支持的 Debian 版本: ${PRETTY_NAME:-unknown}" >&2
    exit 1
    ;;
esac

cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${codename} ${components}
deb http://deb.debian.org/debian ${codename}-updates ${components}
deb http://deb.debian.org/debian-security ${codename}-security ${components}
EOF

apt-get clean
apt-get update -y
