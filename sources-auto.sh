#!/usr/bin/env bash
set -e

. /etc/os-release

case "${VERSION_CODENAME:-}" in
  bullseye)
    codename="bullseye"
    components="main contrib non-free"
    base_url="https://snapshot.debian.org/archive/debian/20260901T000000Z"
    sec_url="https://snapshot.debian.org/archive/debian-security/20260901T000000Z"
    ;;
  bookworm|trixie)
    codename="${VERSION_CODENAME}"
    components="main contrib non-free non-free-firmware"
    base_url="http://deb.debian.org/debian"
    sec_url="http://deb.debian.org/debian-security"
    ;;
  *)
    echo "不支持的 Debian 版本: ${PRETTY_NAME:-unknown}" >&2
    exit 1
    ;;
esac

stamp="$(date +%Y%m%d%H%M%S)"
LIST_DIR=/etc/apt/sources.list.d

cp /etc/apt/sources.list "/etc/apt/sources.list.backup.${stamp}" 2>/dev/null || true

cat > /etc/apt/sources.list <<EOF
deb ${base_url} ${codename} ${components}
deb ${base_url} ${codename}-updates ${components}
deb ${sec_url} ${codename}-security ${components}
EOF

if [ -f "$LIST_DIR/debian.sources" ]; then
  mv -f "$LIST_DIR/debian.sources" "$LIST_DIR/debian.sources.backup.${stamp}"
  echo "已停用 debian.sources (官方源改由 sources.list 提供, 原文件已备份)"
fi

echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99-antnest-apt.conf

apt-get clean

if apt-get update -o Acquire::Retries=6; then
  echo "软件源更新成功"
else
  echo "官方源更新仍失败, 疑似 sources.list.d 中存在损坏的第三方源, 自动停用后重试..." >&2
  for f in "$LIST_DIR"/*.list "$LIST_DIR"/*.sources; do
    if [ -f "$f" ]; then
      mv -f "$f" "${f}.backup.${stamp}"
      echo "已停用第三方源: $f (已备份为 ${f}.backup.${stamp})"
    fi
  done
  apt-get update -o Acquire::Retries=6
fi

ls -1t /etc/apt/sources.list.backup.* 2>/dev/null | tail -n +4 | xargs -r rm -f || true
