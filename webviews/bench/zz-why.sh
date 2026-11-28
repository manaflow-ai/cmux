#!/bin/bash
cd "$(dirname "$0")/.."
python3 bench/zz-why-patch.py && PFX=c VARIANTS="why" exec bash bench/zz-p95.sh
