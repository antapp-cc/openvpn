#!/bin/bash
# Debian 11 sources.list自动替换脚本
# 适用于系统安装完成后自动运行

set -e  # 遇到错误立即退出

echo "开始更新Debian 11软件源配置..."

# 备份原有的sources.list文件
if [ -f /etc/apt/sources.list ]; then
    cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d%H%M%S)
    echo "已备份原有sources.list文件"
fi

# 下载新的sources.list文件
echo "正在从GitHub下载sources.list..."
wget -q -O /tmp/sources.list https://raw.githubusercontent.com/antapp-cc/openvpn/refs/heads/main/sources.list

# 检查下载是否成功
if [ $? -eq 0 ] && [ -s /tmp/sources.list ]; then
    echo "下载成功，正在替换系统源文件..."
    
    # 将下载的文件复制到系统目录
    cp /tmp/sources.list /etc/apt/sources.list
    
    # 设置正确的文件权限
    chmod 644 /etc/apt/sources.list
    chown root:root /etc/apt/sources.list
    
    echo "sources.list文件替换完成"
    
    # 清理临时文件
    rm -f /tmp/sources.list
    
    echo "Debian 11软件源配置更新完成！"
else
    echo "错误：无法下载sources.list文件，请检查网络连接或URL是否有效"
    echo "正在恢复备份文件..."
    if ls /etc/apt/sources.list.backup.* 1> /dev/null 2>&1; then
        cp /etc/apt/sources.list.backup.* /etc/apt/sources.list
    fi
    exit 1
fi
