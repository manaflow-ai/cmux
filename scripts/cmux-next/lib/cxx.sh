# shellcheck shell=bash
# The C++ compiler for the CEF shim's header-only tests (scripts/cmux-next/test-*-cpp.sh):
# CXX when set, else the selected Xcode's clang++ on a Mac, else clang++ (CI runs them on Linux).
if [[ -n "${CXX:-}" ]]; then
  cxx=("$CXX")
elif command -v xcrun >/dev/null 2>&1; then
  cxx=(xcrun clang++)
else
  cxx=(clang++)
fi
