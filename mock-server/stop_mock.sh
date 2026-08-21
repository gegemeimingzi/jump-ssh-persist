#!/bin/bash
# 停止并清理本地 mock 容器
docker rm -f jump-mock 2>/dev/null && echo "mock stopped" || echo "mock not running"
