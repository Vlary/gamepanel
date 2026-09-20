#!/usr/bin/env bash
# 游戏方舟 - 启动脚本
set -e
cd "$(dirname "$0")/.."

export CANGJIE_HOME="${CANGJIE_HOME:-$HOME/cangjie}"
export LD_LIBRARY_PATH="$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$LD_LIBRARY_PATH"

BIN=./target/release/bin/main
if [ ! -x "$BIN" ]; then
    echo "未找到二进制，请先: source scripts/setup-env.sh && cjpm build"
    exit 1
fi

# 环境变量说明：
#   GP_PORT       监听端口（默认 8080）
#   GP_DATA       数据根目录（默认 <项目>/data）
#   GP_ADMIN_PASS 管理员密码（默认 admin123，务必修改）
#   GP_DOCKER     docker 命令（默认 docker）
#   GP_WEB        前端目录（默认 <项目>/web）
exec $BIN
