#!/usr/bin/env bash
set -euo pipefail

GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.30.1}"

repo_root="$(git rev-parse --show-toplevel)"
config_path="$repo_root/.gitleaks.toml"

platform_name() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    *)
      echo "Unsupported gitleaks platform: $(uname -s)" >&2
      return 1
      ;;
  esac
}

arch_name() {
  case "$(uname -m)" in
    arm64 | aarch64) echo "arm64" ;;
    x86_64 | amd64) echo "x64" ;;
    *)
      echo "Unsupported gitleaks architecture: $(uname -m)" >&2
      return 1
      ;;
  esac
}

sha256_check() {
  local checksum_file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$checksum_file"
  else
    shasum -a 256 -c "$checksum_file"
  fi
}

ensure_gitleaks() {
  if [[ -n "${GITLEAKS_BIN:-}" ]]; then
    printf '%s\n' "$GITLEAKS_BIN"
    return
  fi

  local system_gitleaks installed_version
  system_gitleaks="$(command -v gitleaks || true)"
  if [[ -n "$system_gitleaks" ]]; then
    installed_version="$("$system_gitleaks" version 2>/dev/null | awk 'NR == 1 { print $1 }')"
    installed_version="${installed_version#v}"
    if [[ "$installed_version" == "$GITLEAKS_VERSION" ]]; then
      printf '%s\n' "$system_gitleaks"
      return
    fi
    echo "Ignoring system gitleaks ${installed_version:-unknown}; using pinned ${GITLEAKS_VERSION}" >&2
  fi

  local os arch cache_dir asset archive checksum selected_checksum base_url
  os="$(platform_name)"
  arch="$(arch_name)"
  cache_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-gitleaks-${GITLEAKS_VERSION}-${os}-${arch}"
  asset="gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
  archive="$cache_dir/$asset"
  checksum="$cache_dir/gitleaks_${GITLEAKS_VERSION}_checksums.txt"
  selected_checksum="$cache_dir/$asset.sha256"
  base_url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"

  mkdir -p "$cache_dir"
  if [[ ! -x "$cache_dir/gitleaks" ]]; then
    curl -fsSL --connect-timeout 20 --max-time 120 "$base_url/$asset" --output "$archive"
    curl -fsSL --connect-timeout 20 --max-time 120 "$base_url/gitleaks_${GITLEAKS_VERSION}_checksums.txt" --output "$checksum"
    grep "  ${asset}$" "$checksum" > "$selected_checksum"
    (
      cd "$cache_dir"
      sha256_check "$selected_checksum" >&2
    )
    tar -xzf "$archive" -C "$cache_dir" gitleaks
    chmod 0755 "$cache_dir/gitleaks"
  fi

  printf '%s\n' "$cache_dir/gitleaks"
}

scan_dir() {
  local gitleaks_bin="$1"
  local target="$2"
  (
    cd "$target"
    "$gitleaks_bin" dir \
      --no-banner \
      --no-color \
      --redact=100 \
      --config "$config_path" \
      .
  )
}

self_test() {
  local gitleaks_bin allowed_root blocked_root fixture_token out_file err_file
  gitleaks_bin="$(ensure_gitleaks)"
  allowed_root="$(mktemp -d)"
  blocked_root="$(mktemp -d)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  trap 'rm -rf "${allowed_root:-}" "${blocked_root:-}"; rm -f "${out_file:-}" "${err_file:-}"' RETURN
  fixture_token="$(printf 'gh%s_%s%s' "p" "0123456789abcdef" "ABCDEF0123456789abcd")"

  mkdir -p "$allowed_root/Packages/macOS/CmuxFoundation/Tests/CmuxFoundationTests"
  cat > "$allowed_root/Packages/macOS/CmuxFoundation/Tests/CmuxFoundationTests/ScrubberDenylistsTests.swift" <<EOF
let fixture = "clone ${fixture_token} here"
EOF

  scan_dir "$gitleaks_bin" "$allowed_root"

  mkdir -p "$blocked_root/not-allowlisted"
  cat > "$blocked_root/not-allowlisted/leak.swift" <<EOF
let leak = "${fixture_token}"
EOF

  set +e
  scan_dir "$gitleaks_bin" "$blocked_root" >"$out_file" 2>"$err_file"
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "Expected seeded leak outside allowlisted paths to fail gitleaks." >&2
    cat "$out_file" >&2
    cat "$err_file" >&2
    return 1
  fi
  if [[ "$rc" -ne 1 ]]; then
    echo "Gitleaks failed unexpectedly while checking seeded leak (exit $rc)." >&2
    cat "$out_file" >&2
    cat "$err_file" >&2
    return "$rc"
  fi

  echo "PASS: gitleaks allowlist suppresses only the fixture path and still fails on seeded leaks"
}

main() {
  case "${1:-}" in
    --self-test)
      self_test
      ;;
    *)
      scan_dir "$(ensure_gitleaks)" "$repo_root"
      ;;
  esac
}

main "$@"
