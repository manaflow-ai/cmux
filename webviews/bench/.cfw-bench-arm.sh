#!/usr/bin/env bash
# usage: bench-arm.sh ROWS [ARM]  (ARM empty: default arm)
cd webviews || exit 1
[ -n "$2" ] && export EXPERIMENTS="{\"hidden-measure-caches\":\"$2\"}"
CASES=grown-many REPEAT=1 IDLE_S=5 STREAM_S=5 bun bench/chat-100k-flat.bench.ts "$1" 20
