#!/bin/sh
# 构建 CLI：bin/t88ctl（仅依赖 Xcode Command Line Tools 自带的 swiftc 与 IOKit）
# 源文件：src/main.swift（入口与命令）+ src/T88Protocol.swift（与 GUI 共用的协议层）
set -eu
cd "$(dirname "$0")/.."
mkdir -p bin
swiftc -O -o bin/t88ctl src/main.swift src/T88Protocol.swift
echo "构建完成: $(pwd)/bin/t88ctl"
