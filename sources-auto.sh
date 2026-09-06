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

stamp="$(date +%Y%m%d%H%M%S)"
LIST_DIR=/etc/apt/sources.list.d

# 1) 备份并重写主源文件
cp /etc/apt/sources.list "/etc/apt/sources.list.backup.${stamp}" 2>/dev/null || true

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${codename} ${components}
deb http://deb.debian.org/debian ${codename}-updates ${components}
deb http://deb.debian.org/debian-security ${codename}-security ${components}
EOF

# 2) 官方 deb822 源与重写后的 sources.list 内容重复, 统一停用(备份), 避免双重定义
if [ -f "$LIST_DIR/debian.sources" ]; then
  mv -f "$LIST_DIR/debian.sources" "$LIST_DIR/debian.sources.backup.${stamp}"
  echo "已停用 debian.sources (官方源改由 sources.list 提供, 原文件已备份)"
fi

apt-get clean

# 3) 第一次尝试: 仅官方源更新
if apt-get update; then
  echo "软件源更新成功"
else
  # 4) 仍失败则说明 sources.list.d 里存在损坏的第三方源, 停用后重试 (文件均有备份)
  echo "官方源更新仍失败, 疑似 sources.list.d 中存在损坏的第三方源, 自动停用后重试..." >&2
  for f in "$LIST_DIR"/*.list "$LIST_DIR"/*.sources; do
    if [ -f "$f" ]; then
      mv -f "$f" "${f}.backup.${stamp}"
      echo "已停用第三方源: $f (已备份为 ${f}.backup.${stamp})"
    fi
  done
  apt-get update
fi

# 5) 主源备份只保留最近 3 份, 防止无限累积
ls -1t /etc/apt/sources.list.backup.* 2>/dev/null | tail -n +4 | xargs -r rm -f || true
