#!/usr/bin/env bash
# Cài pagent vào PATH (symlink) + thêm export vào shell rc
set -euo pipefail
PREFIX="${PREFIX:-$HOME/.local/bin}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_RC="${SHELL_RC:-$HOME/.zshrc}"

COMPDIR="${COMPDIR:-$HOME/.zsh/completions}"
mkdir -p "$PREFIX" "$COMPDIR"
chmod +x "$SRC_DIR/pagent" "$SRC_DIR/kit/hooks/"*.sh
ln -sfn "$SRC_DIR/pagent" "$PREFIX/pagent"
echo "✓ symlink $PREFIX/pagent → $SRC_DIR/pagent"
ln -sfn "$SRC_DIR/kit/completions/_pagent" "$COMPDIR/_pagent"
echo "✓ symlink $COMPDIR/_pagent (zsh completion)"

if ! grep -q "# pagent CLI" "$SHELL_RC" 2>/dev/null; then
  cat >>"$SHELL_RC" <<EOF

# pagent CLI
export PATH="$PREFIX:\$PATH"
fpath=($COMPDIR \$fpath)
autoload -Uz compinit && compinit -i
# Override mặc định bằng .env.pagent trong project:
# export PAGENT_REPORT_DIR="\$HOME/.pagent-reports"
# export PAGENT_MODEL="claude-sonnet-4-6"
EOF
  echo "✓ thêm pagent + completion vào $SHELL_RC"
  echo "  Mở terminal mới hoặc:  source $SHELL_RC"
else
  echo "✓ $SHELL_RC đã có pagent (kiểm tra fpath có $COMPDIR chưa)"
fi

cat <<EOF

Bắt đầu trong project:
  cd ~/your-project
  cp $SRC_DIR/.env.pagent.example .env.pagent && \$EDITOR .env.pagent
  pagent env             # check biến môi trường
  pagent init            # sinh .pagent/source-summary.md
  pagent feature "Thêm endpoint POST /users"
  pagent fix "Lỗi 500 khi login với email viết hoa"
  pagent report          # xem tổng kết + cost
EOF
