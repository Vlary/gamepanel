#!/usr/bin/env bash
# 游戏方舟 - 开发/构建环境初始化
# 用法: source scripts/setup-env.sh
#
# 前置条件（一次性）：
#   1) 仓颉 SDK 1.1.3 解压至 ~/cangjie（或设置 CANGJIE_HOME 指向解压目录）
#      下载: https://cangjie-lang.cn/download → cangjie-sdk-linux-x64-1.1.3.tar.gz
#   2) stdx 1.1.3.1 扩展库安装（net.http / encoding.json 等）:
#      bash -c "$(curl -fsSL https://raw.gitcode.com/Cangjie/cangjie_stdx/raw/main/downloader.sh)" -- 1.1.3.1 -p linux-x64 -d /tmp/stdx
#      cp -r /tmp/stdx/cangjie-stdx-linux-x64-1.1.3.1/linux_x86_64_cjnative/static/stdx $CANGJIE_HOME/modules/linux_x86_64_cjnative/
#
# 本脚本只做: 设置编译运行所需的环境变量

export CANGJIE_HOME="${CANGJIE_HOME:-$HOME/cangjie}"
if [ ! -d "$CANGJIE_HOME" ]; then
    echo "错误: 未找到仓颉 SDK（$CANGJIE_HOME）。请先按上方注释安装。" >&2
    return 1 2>/dev/null || exit 1
fi
export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
export LD_LIBRARY_PATH="$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$LD_LIBRARY_PATH"

echo "仓颉环境就绪: $(cjc --version 2>/dev/null | head -1)"
echo "构建: cd gamepanel && cjpm build"
echo "运行: ./target/release/bin/main   (详见 scripts/run.sh)"
