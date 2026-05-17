#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/.deps"
mkdir -p "$DEPS"
if [ ! -d "$DEPS/plenary.nvim" ]; then
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$DEPS/plenary.nvim"
fi
