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

# Repo-pinned SHA-256 checksums for the gitleaks release archives. Committed here
# (and reviewed in PRs) so this required CI gate verifies the downloaded binary
# against a trust anchor inside the repository rather than a checksum fetched
# from the same mutable release: if the upstream release assets are later
# replaced or the account is compromised, the archive will no longer match and
# the scan fails closed instead of executing an attacker-controlled binary.
# Update these when bumping GITLEAKS_VERSION (values come from the upstream
# gitleaks_<version>_checksums.txt).
gitleaks_pinned_sha256() {
  local os="$1" arch="$2"
  case "${GITLEAKS_VERSION}_${os}_${arch}" in
    8.30.1_darwin_arm64) echo "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5" ;;
    8.30.1_darwin_x64) echo "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709" ;;
    8.30.1_linux_arm64) echo "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080" ;;
    8.30.1_linux_x64) echo "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ;;
    *)
      echo "No pinned gitleaks checksum for version ${GITLEAKS_VERSION} on ${os}/${arch}." >&2
      echo "Add it to gitleaks_pinned_sha256() in scripts/secret-scan.sh when bumping the version." >&2
      return 1
      ;;
  esac
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

  local work asset base_url expected_sha
  asset="gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
  base_url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"
  # Resolve the trust anchor before downloading anything; fail closed if this
  # version/platform is not pinned in the repo.
  expected_sha="$(gitleaks_pinned_sha256 "$os" "$arch")" || return 1
  work="$(mktemp -d)"

  # Download and verify into a private, unpredictable work dir (mktemp -d is mode
  # 0700), then install atomically into the cache. Nothing is executed from a
  # shared or attacker-writable location, and the archive is verified against the
  # repo-pinned checksum (not one fetched from the same release) before
  # extraction. The && chain stops at the first failure so a network error never
  # runs later steps or installs a partial binary, and the subshell EXIT trap is
  # local, so it never disturbs the RETURN trap that self_test installs in the
  # parent shell. errexit is not inherited into the $(ensure_gitleaks) command
  # substitution, so failures are handled explicitly.
  (
    trap 'rm -rf "$work"' EXIT
    cd "$work" &&
      printf '%s  %s\n' "$expected_sha" "$asset" > "$asset.sha256" &&
      curl -fsSL --connect-timeout 20 --max-time 120 "$base_url/$asset" --output "$asset" &&
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
  local gitleaks_bin allowed_root blocked_root prod_root fixture_token out_file err_file
  gitleaks_bin="$(ensure_gitleaks)"
  allowed_root="$(mktemp -d)"
  blocked_root="$(mktemp -d)"
  prod_root="$(mktemp -d)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  trap 'rm -rf "${allowed_root:-}" "${blocked_root:-}" "${prod_root:-}"; rm -f "${out_file:-}" "${err_file:-}"' RETURN
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

  # Regression guard for allowlist scope: the production scrubber source is
  # exempt only for its single generic-api-key doc example, so a private key
  # accidentally committed to that file must still be caught (not suppressed).
  # Assemble the PEM markers at runtime (like fixture_token) so this script does
  # not itself contain a scannable "-----BEGIN ... PRIVATE KEY-----" literal.
  local pem_dashes pem_fixture
  pem_dashes="-----"
  pem_fixture="${pem_dashes}BEGIN RSA PRIVATE KEY${pem_dashes}\\nMIIEpAIBAAKCAQEAsecretbodyabc/def+ghi==\\n${pem_dashes}END RSA PRIVATE KEY${pem_dashes}"
  mkdir -p "$prod_root/Packages/macOS/CmuxFoundation/Sources/CmuxFoundation"
  printf 'let leaked = "%s"\n' "$pem_fixture" \
    > "$prod_root/Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/SentryScrubber.swift"
  set +e
  scan_dir "$gitleaks_bin" "$prod_root" >"$out_file" 2>"$err_file"
  local prod_rc=$?
  set -e
  if [[ "$prod_rc" -eq 0 ]]; then
    echo "Expected a private key in production scrubber source to be caught; the allowlist is too broad." >&2
    cat "$out_file" >&2
    cat "$err_file" >&2
    return 1
  fi
  if [[ "$prod_rc" -ne 1 ]]; then
    echo "Gitleaks failed unexpectedly while checking production scrubber source (exit $prod_rc)." >&2
    cat "$out_file" >&2
    cat "$err_file" >&2
    return "$prod_rc"
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
