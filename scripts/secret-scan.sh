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

# Verify that file $2 matches the expected SHA-256 $1, feeding the check list on
# stdin so no attacker-writable checksum file is involved in the comparison.
verify_sha256() {
  local expected="$1" file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
  else
    printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c -
  fi
}

# Repo-pinned SHA-256 trust anchors for gitleaks, committed here (and reviewed in
# PRs) so this required CI gate verifies what it executes against a checksum
# inside the repository rather than one fetched from the same mutable release: if
# the upstream assets are later replaced or the account is compromised, the
# download no longer matches and the scan fails closed instead of running an
# attacker-controlled binary. The archive hash gives a fail-fast check on the
# download; the binary hash is the anchor for the executable itself and is
# re-checked on every cache reuse so a poisoned cache entry can never run.
# Update BOTH when bumping GITLEAKS_VERSION: the archive value comes from the
# upstream gitleaks_<version>_checksums.txt, the binary value is the sha256 of
# the `gitleaks` file inside that archive.
gitleaks_pinned_sha256() {
  local os="$1" arch="$2"
  case "${GITLEAKS_VERSION}_${os}_${arch}" in
    8.30.1_darwin_arm64) echo "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5" ;;
    8.30.1_darwin_x64) echo "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709" ;;
    8.30.1_linux_arm64) echo "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080" ;;
    8.30.1_linux_x64) echo "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ;;
    *)
      echo "No pinned gitleaks archive checksum for version ${GITLEAKS_VERSION} on ${os}/${arch}." >&2
      echo "Add it to gitleaks_pinned_sha256() in scripts/secret-scan.sh when bumping the version." >&2
      return 1
      ;;
  esac
}

gitleaks_pinned_binary_sha256() {
  local os="$1" arch="$2"
  case "${GITLEAKS_VERSION}_${os}_${arch}" in
    8.30.1_darwin_arm64) echo "ba52fb1bfabbcde42f032afad3d6e0b19dff8ed105229a16e7caa338bbc0e84f" ;;
    8.30.1_darwin_x64) echo "cee01fea7173f1b779dff188e1c26ecbcb4027d394acc573b23aaf0be260e291" ;;
    8.30.1_linux_arm64) echo "00e91bbe655bd7c47753e8cfe61cb76ea1a5d7e7702fe161ee40102b46b3823b" ;;
    8.30.1_linux_x64) echo "88f91962aa2f93ac6ab281d553b9e125f5197bbbce38f9f2437f7299c32e5509" ;;
    *)
      echo "No pinned gitleaks binary checksum for version ${GITLEAKS_VERSION} on ${os}/${arch}." >&2
      echo "Add it to gitleaks_pinned_binary_sha256() in scripts/secret-scan.sh when bumping the version." >&2
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

  local os arch cache_dir bin expected_bin_sha system_gitleaks
  os="$(platform_name)"
  arch="$(arch_name)"
  expected_bin_sha="$(gitleaks_pinned_binary_sha256 "$os" "$arch")" || return 1
  cache_dir="$(gitleaks_cache_dir "$os" "$arch")"
  bin="$cache_dir/gitleaks"

  # Use a gitleaks already on PATH only if it is byte-identical to the pinned
  # release binary. A matching version string is not trusted on its own: a
  # poisoned scanner on a persistent/self-hosted runner could simply print the
  # expected version to take over this required gate.
  system_gitleaks="$(command -v gitleaks || true)"
  if [[ -n "$system_gitleaks" ]]; then
    if verify_sha256 "$expected_bin_sha" "$system_gitleaks" >/dev/null 2>&1; then
      printf '%s\n' "$system_gitleaks"
      return
    fi
    echo "System gitleaks does not match pinned ${GITLEAKS_VERSION} binary; using pinned download." >&2
  fi

  # Reuse a cached binary only if it matches the repo-pinned binary checksum, so a
  # stale or poisoned cache entry (e.g. one seeded by an earlier job on a
  # persistent/self-hosted runner) is never executed without re-checking the
  # repository trust anchor.
  if [[ -x "$bin" ]] && verify_sha256 "$expected_bin_sha" "$bin" >/dev/null 2>&1; then
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

  # Download into a private, unpredictable work dir (mktemp -d is mode 0700),
  # verify the archive against the repo-pinned archive checksum (a fail-fast
  # check on the download, not one fetched from the same release), extract, then
  # verify the extracted binary against the repo-pinned binary checksum before
  # installing it. Nothing is executed from a shared or attacker-writable
  # location. The && chain stops at the first failure so a network error never
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
      verify_sha256 "$expected_bin_sha" gitleaks >&2 &&
      mkdir -p "$cache_dir" &&
      { chmod 0700 "$cache_dir" 2>/dev/null || true; } &&
      mv -f gitleaks "$bin"
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
