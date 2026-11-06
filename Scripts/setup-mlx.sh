#!/bin/bash
# Prepare this Mac's project-local MLX runtime. No system Python packages change.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${MYPLAMO_PYTHON:-/opt/homebrew/bin/python3.13}"
if [ ! -x "$python_bin" ]; then
  if command -v brew >/dev/null 2>&1; then
    brew install python@3.13
    python_bin="$(brew --prefix python@3.13)/bin/python3.13"
  else
    printf '%s\n' 'Python 3.13 is required. Install Python 3.13 and set MYPLAMO_PYTHON to its path.' >&2
    exit 1
  fi
fi
"$python_bin" -c 'import platform,sys; assert platform.system()=="Darwin" and platform.machine()=="arm64", "Apple Silicon Mac required"; assert sys.version_info[:2]==(3,13), "Python 3.13 required"'
"$python_bin" -m venv "$project_dir/.venv"
"$project_dir/.venv/bin/python" -m pip install --disable-pip-version-check -r "$project_dir/Runtime/requirements-mlx.lock"
"$project_dir/.venv/bin/python" -c 'import mlx.core as mx, mlx_lm, numba, transformers; assert mx.metal.is_available(), "Metal GPU unavailable"; print("MLX runtime ready:", mx.__version__)'
