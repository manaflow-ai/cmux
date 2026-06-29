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

sha256_sum() {
  local target="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target"
  else
    shasum -a 256 "$target"
  fi
}

# Resolve the per-user cache directory for the pinned gitleaks binary. The base
# is a user-private location (XDG_CACHE_HOME or ~/.cache), never a world-writable
# shared temp dir, so another local user cannot pre-seed this predictable path
# with an attacker-controlled executable.
gitleaks_cache_dir() {
  local os="$1" arch="$2" base
  if [[ -n "${CMUX_GITLEAKS_CACHE_DIR:-}" ]]; then
    base="$CMUX_GITLEAKS_CACHE_DIR"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    base="$XDG_CACHE_HOME/cmux-gitleaks"
  elif [[ -n "${HOME:-}" ]]; then
    base="$HOME/.cache/cmux-gitleaks"
  else
    # No user-private base available; fall back to an unpredictable private dir.
    base="$(mktemp -d)"
  fi
  printf '%s/%s-%s-%s\n' "$base" "$GITLEAKS_VERSION" "$os" "$arch"
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

  local os arch cache_dir bin
  os="$(platform_name)"
  arch="$(arch_name)"
  cache_dir="$(gitleaks_cache_dir "$os" "$arch")"
  bin="$cache_dir/gitleaks"

  # Reuse a cached binary only after re-verifying its recorded checksum, so a
  # tampered or corrupted file at this path is never executed without validation.
  if [[ -x "$bin" && -f "$cache_dir/gitleaks.sha256" ]] \
    && (cd "$cache_dir" && sha256_check gitleaks.sha256 >/dev/null 2>&1); then
    printf '%s\n' "$bin"
    return
  fi

  # Download and verify into a private, unpredictable work dir (mktemp -d is
  # mode 0700), then install atomically into the cache. Nothing is executed from
  # a shared or attacker-writable location, and the upstream archive checksum is
  # always verified before extraction.
  local work asset base_url
  work="$(mktemp -d)"
  asset="gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
  base_url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"

  # Download/verify/install in a subshell whose EXIT trap always removes the work
  # dir, even when a step fails. The && chain stops at the first failure (so a
  # network error never runs later steps or installs a partial binary), and the
  # subshell EXIT trap is local, so it never disturbs the RETURN trap that
  # self_test installs in the parent shell. errexit is not inherited into the
  # $(ensure_gitleaks) command substitution, so failures are handled explicitly.
  (
    trap 'rm -rf "$work"' EXIT
    cd "$work" &&
      curl -fsSL --connect-timeout 20 --max-time 120 "$base_url/$asset" --output "$asset" &&
      curl -fsSL --connect-timeout 20 --max-time 120 "$base_url/gitleaks_${GITLEAKS_VERSION}_checksums.txt" --output checksums.txt &&
      grep "  ${asset}$" checksums.txt > "$asset.sha256" &&
      sha256_check "$asset.sha256" >&2 &&
      tar -xzf "$asset" gitleaks &&
      chmod 0755 gitleaks &&
      sha256_sum gitleaks > gitleaks.sha256 &&
      mkdir -p "$cache_dir" &&
      { chmod 0700 "$cache_dir" 2>/dev/null || true; } &&
      mv -f gitleaks "$bin" &&
      mv -f gitleaks.sha256 "$cache_dir/gitleaks.sha256"
  ) || {
    echo "Failed to download and verify pinned gitleaks ${GITLEAKS_VERSION}." >&2
    return 1
  }

  printf '%s\n' "$bin"
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
      # Assign on its own line (not `local x=...`) so set -e aborts when
      # ensure_gitleaks fails instead of running scan_dir with an empty binary.
      local gitleaks_bin
      gitleaks_bin="$(ensure_gitleaks)"
      scan_dir "$gitleaks_bin" "$repo_root"
      ;;
  esac
}

main "$@"
