#!/usr/bin/env bash
# cargo fmt for the cmux-tui workspace: run from cmux-tui/, extra args (--check) go to cargo fmt.
#
# A crate whose tests/ files are modules of one `it` binary (tests/it/main.rs, #56677) reaches them
# through a generated list cargo fmt cannot follow, so they are named to rustfmt. They are named on
# a run for that crate alone (-p): `cargo fmt --all -- FILES` appends FILES to every edition's
# rustfmt run, so the 2021 crates' run parsed these 2024 files and failed on let chains, which
# stopped the base autofix before it pushed any repair (#56928).
set -euo pipefail
cargo fmt --all "$@"
for it_main in crates/*/tests/it/main.rs; do
  [[ -f "$it_main" ]] || continue
  crate="${it_main%/tests/it/main.rs}"
  pkg="$(awk '/^\[/{p=($0=="[package]")} p&&/^name *=/{gsub(/^name *= *"|".*$/,"");print;exit}' "$crate/Cargo.toml")"
  [[ -n "$pkg" ]] || { echo "cmux-tui-fmt: no [package] name in $crate/Cargo.toml" >&2; exit 1; }
  cargo fmt -p "$pkg" "$@" -- "$crate"/tests/*.rs
done
