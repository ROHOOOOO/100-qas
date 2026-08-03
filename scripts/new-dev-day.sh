#!/usr/bin/env sh
set -eu

DAY="${1:-$(date +%F)}"
DIR="dev-days/$DAY"

mkdir -p "$DIR"

if [ ! -f "$DIR/README.md" ]; then
  cat > "$DIR/README.md" <<EOF
# $DAY 开发日记录

## 当天目标

- 

## 项目上下文

- 
EOF
fi

if [ ! -f "$DIR/done.md" ]; then
  cat > "$DIR/done.md" <<EOF
# $DAY 已完成事项

- 
EOF
fi

if [ ! -f "$DIR/todo.md" ]; then
  cat > "$DIR/todo.md" <<EOF
# $DAY 待办事项

- 
EOF
fi

echo "Daily development log is ready: $DIR"

