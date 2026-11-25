#!/usr/bin/env bash
# After build-xcframework.sh on a Mac: fail when the checked-in uniffi bindings
# (cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift) or Cargo.lock differ from what
# it generated. The xcframework and target/ are gitignored; the script rewrites the bindings and restores
# Cargo.lock, so any tracked change under cmux-next-ios/ is drift, except an order-only one.
#
# uniffi-bindgen emits top-level functions in the library's symbol order: symtab order in a Linux .so (ELF, where
# scripts/ios-ffi-bindings.sh and the base autofix write the file), nlist order in a Mac .dylib (Mach-O, here;
# uniffi_bindgen 0.31 macro_metadata/extract.rs). The two differ, so a byte compare kept every Mac kit run red on a
# file the autofix had just written (run 45571735015: setLanMemoryDir one function earlier, nothing else). Swift
# top-level declarations do not depend on their order, so the same lines in another order pass; any added, removed
# or changed line still fails.
set -euo pipefail
rel=cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift
fail() {
  echo "::error::build-xcframework.sh changed tracked files ($*). The base autofix regenerates the bindings (scripts/ios-ffi-bindings.sh, base-autofix.sh --ios-ffi); a pull request's autofix re-run does too"
  exit 1
}
git diff --quiet -- cmux-next-ios/ && exit 0
others="$(git diff --name-only -- cmux-next-ios/ | grep -v -x -F "$rel" || true)"
if [[ -n "$others" ]]; then
  git diff -- cmux-next-ios/
  fail "$(echo "$others" | tr '\n' ' ')"
fi
if cmp -s <(git show "HEAD:$rel" | LC_ALL=C sort) <(LC_ALL=C sort "$rel"); then
  echo "CmuxMobileLinkFFI.swift: the same declarations in the Mac library's symbol order (the file is written on Linux); no drift"
  git checkout -- "$rel"
  exit 0
fi
git diff -- "$rel"
fail "CmuxMobileLinkFFI.swift"
