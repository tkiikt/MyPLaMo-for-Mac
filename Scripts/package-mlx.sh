#!/bin/bash
# Bundle the installed CPython + pinned MLX environment into an app resource dir.
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:?Specify output runtime directory}"
.venv/bin/python Scripts/package_mlx.py "$destination"
PYTHONHOME="$destination" PYTHONNOUSERSITE=1 "$destination/bin/python3" -c 'import mlx.core as mx, mlx_lm, numba, transformers; assert mx.metal.is_available(); print("Bundled MLX", mx.__version__)'
