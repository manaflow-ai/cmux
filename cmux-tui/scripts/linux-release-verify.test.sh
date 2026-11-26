#!/bin/sh
# Tests the signed Linux release file path of the installers (cmuxterm-hq
# docs/design/linux-signed-packages.md, section 8):
#   sh cmux-tui/scripts/linux-release-verify.test.sh
# 1. The copies of linux-release-verify.sh in web/public/tui/install-static.sh
#    and cmux-tui/scripts/machine-join.sh, and their keys, equal the source,
#    web-update-keys.json, channel.rs KEYS and the Cloud bake's LINUX_RELEASE_KEYS
#    in web/services/vms/drivers/linuxRelease.ts (linux-release-verify-gen.py --check).
# 2. Every curl and fetch in both scripts downloads the signed file, a URL taken
#    from it, or one of the named unsigned downloads below (each marked in the
#    script with why).
# 3. The shipped install-static.sh, with a generated test key in place of the
#    release keys, against a fixture files.cmux.com (a fake curl): a valid file
#    installs; each bad file is refused with a last `next:` line and nothing installed.
# Needs OpenSSL 3, python3 and awk.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
gen="$here/linux-release-verify-gen.py"
install_static="$repo/web/public/tui/install-static.sh"
machine_join="$here/machine-join.sh"
root="$(mktemp -d "${TMPDIR:-/tmp}/linux-release-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT INT TERM
. "$here/linux-release-fixture.sh"

fails=0
passes=0
case_name=""
fail() {
  fails=$((fails + 1))
  printf 'FAIL [%s] %s\n' "$case_name" "$*" >&2
}
check() { # DESCRIPTION COMMAND...
  desc="$1"
  shift
  if "$@"; then passes=$((passes + 1)); else fail "$desc"; fi
}

# 1. The inline copies and the keys.
case_name=generated
check "the inline copies or keys drifted: $(python3 "$gen" --check 2>&1)" python3 "$gen" --check

# 2. Every download. Comments and the generated block are skipped; continued
# lines are joined; what is left that runs curl or fetch must be one of these.
case_name=fetches
downloads() { # SCRIPT: each line (continuations joined) that runs curl or fetch
  awk '
    /^# BEGIN linux-release-verify/ { skip = 1 }
    /^# END linux-release-verify/ { skip = 0; next }
    skip { next }
    { line = held $0; held = "" }
    /\\$/ { sub(/\\$/, "", line); held = line; next }
    line ~ /^[[:space:]]*#/ { next }
    {
      # Words inside quotes (a message naming curl) and `command -v curl` run nothing.
      code = line
      gsub(/"[^"]*"/, "\"\"", code)
      gsub(/\047[^\047]*\047/, "", code)
      sub(/#.*/, "", code)
      gsub(/command -v (curl|fetch)/, "", code)
    }
    code ~ /(^|[[:space:];|&({!])(curl|fetch)([[:space:]]|$)/ && code !~ /^[[:space:]]*(curl|fetch)\(\)/ { print line }
  ' "$1"
}
allowed() { # LINE: a download whose bytes are the signed file, from it, or a named exception
  case "$1" in
    # machine-join's fetch(): the one curl its callers (each checked here) go through.
    *"curl --proto '=https' --tlsv1.2 -fsSL \"\$1\" -o \"\$2\" || fetch_rc=\$?") return 0 ;;
    # Not a download: the anonymous install count, a POST whose answer is dropped.
    *"https://cmux.com/api/install-events"*) return 0 ;;
    # Which commit the NIGHTLY app runs; its release.json is then verified (and its sequence checked).
    *'"$feed_url"'*) return 0 ;;
    # The vendor's own installer for Claude Code, not ours.
    *"fetch https://claude.ai/install.sh "*) return 0 ;;
    # Outside the Linux release file: macOS (no darwin target, no OpenSSL 3).
    *"# unsigned: macOS only") return 0 ;;
    # machine-join's acpmux until phase 1b names it in the signed file.
    *'"$files/channels/$channel.json"'*"# unsigned: phase-1b pending") return 0 ;;
    *'"$files/tree/$key/cmux-tui-acpmux-$target"'*"# unsigned: phase-1b pending") return 0 ;;
    # cmux-rd: not in the release file's names yet.
    *'"$files/tree/$key/cmux-tui-rd-$rd_target"'*"# unsigned: not in the release file") return 0 ;;
  esac
  return 1
}
for s in "$install_static" "$machine_join"; do
  downloads "$s" >"$root/downloads"
  check "${s#"$repo/"}: no download found (the detector reads nothing)" test -s "$root/downloads"
  while IFS= read -r line; do
    check "${s#"$repo/"}: a download not from the signed release file: $line" allowed "$line"
  done <"$root/downloads"
done
# The unsigned ones are counted, so a new one is a failure here too.
check "install-static.sh: expected 2 macOS-only downloads" \
  test "$(downloads "$install_static" | grep -c '# unsigned: macOS only$')" = 2
check "machine-join.sh: expected 2 macOS-only, 2 phase-1b, 1 cmux-rd unsigned downloads" \
  test "$(downloads "$machine_join" | grep -c '# unsigned: ')" = 5
# The detector sees a new one: a copy with one more raw curl fails it.
sed 's|^umask "\$old_umask"$|curl -fsSL https://files.cmux.com/cmux-tui/latest/manifest.json -o "$tmp_dir/m"\n&|' \
  "$install_static" >"$root/mutant.sh"
bad=0
while IFS= read -r line; do allowed "$line" || bad=1; done <<EOF
$(downloads "$root/mutant.sh")
EOF
check "the detector missed an unsigned curl in a mutant" test "$bad" = 1

# 3. The fixture run.
lrf_key "$root/key"
lrf_key "$root/other"
python3 "$gen" --render "$install_static" --keys "$root/key/keys.json" >"$root/install-static.sh"
check "the test key is in the rendered script" grep -q "$(cat "$root/key/id")" "$root/install-static.sh"

shims="$root/shims"
mkdir -p "$shims"
# files.cmux.com from $LRT_SERVE: -o or stdout; --max-filesize only as a real
# server without a Content-Length does (the stream is cut by the reader).
cat >"$shims/curl" <<'EOF'
#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o | --proto | --proto-redir | --max-filesize | --max-time | -H | -d) [ "$1" != -o ] || out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >>"$LRT_LOG"
case "$url" in
  https://files.cmux.com/cmux-tui/*) src="$LRT_SERVE/${url#https://files.cmux.com/cmux-tui/}" ;;
  https://files-next.cmux.com/*) src="$LRT_SERVE/feed.xml" ;;
  https://cmux.com/api/install-events) exit 0 ;;
  *) exit 6 ;;
esac
[ -f "$src" ] || exit 22
if [ -n "$out" ]; then cat "$src" >"$out"; else cat "$src"; fi
EOF
cat >"$shims/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac
EOF
chmod 755 "$shims/curl" "$shims/uname"

target=x86_64-unknown-linux-gnu
c1=1111111111111111111111111111111111111111
c2=2222222222222222222222222222222222222222
c3=3333333333333333333333333333333333333333
tree=abababababababababababababababababababab
now="$(date +%s)"
later=$((now + 86400))
head -c 5000 /dev/urandom >"$root/bin1"
head -c 6000 /dev/urandom >"$root/bin2"
head -c 7000 /dev/urandom >"$root/bin3"
head -c 4000 /dev/urandom >"$root/hook"

# OUT COMMIT VERSION_STAMP EXPIRES TARGET_ENTRIES [EXTRA_FIELDS]: a payload, compact, sorted.
payload() {
  printf '{"channel":"feat-cmux-next","commit":"%s","committed_at":1795341681,"expires_at":%s,"published_at":1795344518,"purpose":"cmux-linux-release","schema":1,%s"targets":{"%s":{%s}},"version":"1.0.0+%s.%s"}' \
    "$2" "$4" "${6:-}" "$target" "$5" "$3" "$(printf '%s' "$2" | cut -c 1-12)" >"$1"
}
# DIR COMMIT BIN: the two files phase 1 publishes for COMMIT, serving BIN.
entries() {
  mkdir -p "$1/$2"
  cp "$3" "$1/$2/cmux-tui-$target"
  cp "$root/hook" "$1/$2/cmux-tui-hook-$target"
  printf '%s,%s' "$(lrf_entry cmux-tui "https://files.cmux.com/cmux-tui/$2/cmux-tui-$target" "$3")" \
    "$(lrf_entry cmux-tui-hook "https://files.cmux.com/cmux-tui/$2/cmux-tui-hook-$target" "$root/hook")"
}

new_case() {
  case_name="$1"
  d="$root/case-$1"
  mkdir -p "$d/home" "$d/serve/channels" "$d/tmp"
  : >"$d/log"
}
# Publish PAYLOAD (signed by KEYDIR, default the test key) as the pointer and as its commit's release.json.
publish() { # PAYLOAD COMMIT [KEYDIR]
  lrf_sign "$1" "${3:-$root/key}" "$d/serve/channels/linux-feat-cmux-next.json"
  mkdir -p "$d/serve/$2"
  cp "$d/serve/channels/linux-feat-cmux-next.json" "$d/serve/$2/release.json"
}
run() {
  rc=0
  env -i HOME="$d/home" PATH="$shims:$PATH" TMPDIR="$d/tmp" SHELL=/bin/sh \
    LRT_SERVE="$d/serve" LRT_LOG="$d/log" sh "$root/install-static.sh" "$@" >"$d/out" 2>"$d/err" || rc=$?
}
installed_is() { cmp -s "$d/home/.cmux/bin/cmux" "$1"; }
nothing_installed() { [ ! -e "$d/home/.cmux/bin/cmux" ]; }
last_is_next() { tail -n 1 "$d/err" | grep -q '^next: '; }
err_has() { grep -qF -- "$1" "$d/err"; }
refused() { # WHAT: exit 1, the reason named, next: last, no binary
  check "refused (rc $rc): $(cat "$d/err")" test "$rc" = 1
  check "says why ($1): $(cat "$d/err")" err_has "$1"
  check "ends with a next: line: $(tail -n 1 "$d/err")" last_is_next
}

new_case valid
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
run
check "exit 0 (rc $rc): $(cat "$d/err")" test "$rc" = 0
check "installed the signed binary" installed_is "$root/bin1"
check "recorded version and sequence: $(cat "$d/home/.cmux/installed.json" 2>/dev/null)" \
  grep -qF '"sequence":20261101000000' "$d/home/.cmux/installed.json"
check "read the signed pointer, not latest/manifest.json" \
  sh -c '! grep -q manifest.json "$1" && grep -q channels/linux-feat-cmux-next.json "$1"' _ "$d/log"
check "downloaded only the pointer and URLs it names: $(cat "$d/log")" \
  test "$(grep -vc -e '/channels/linux-feat-cmux-next.json$' -e "/$c1/cmux-tui-$target\$" -e install-events "$d/log")" = 0

new_case streams-past-size
head -c 5000 "$root/bin1" >"$d/signed"
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$d/signed")"
publish "$d/p" "$c1"
head -c 200000 /dev/urandom >>"$d/serve/$c1/cmux-tui-$target"
run
refused "larger than its signed size"
check "nothing installed" nothing_installed
check "cut off at size + 1 bytes" sh -c '! ls "$1"/cmux-install.*/cmux 2>/dev/null' _ "$d/tmp"

new_case unknown-key
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1" "$root/other"
run
refused "not signed by a cmux release key"
check "nothing installed" nothing_installed
check "no binary downloaded" sh -c '! grep -q cmux-tui-x86 "$1"' _ "$d/log"

new_case tampered-payload
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
# The signature over one payload, carried by another: the key matches, the bytes do not.
payload "$d/p2" "$c1" 20261101000000 "$((later + 1))" "$(entries "$d/serve" "$c1" "$root/bin1")"
sig="$(sed 's/.*"sig":"\([^"]*\)".*/\1/' "$d/serve/channels/linux-feat-cmux-next.json")"
printf '{"payload":"%s","schema":1,"signatures":[{"key_id":"%s","sig":"%s"}]}' \
  "$(openssl base64 -A -in "$d/p2")" "$(cat "$root/key/id")" "$sig" >"$d/serve/channels/linux-feat-cmux-next.json"
run
refused "not signed by a cmux release key"
check "nothing installed" nothing_installed

new_case off-prefix
e="$(entries "$d/serve" "$c2" "$root/bin1")"
payload "$d/p" "$c1" 20261101000000 "$later" "$e"
publish "$d/p" "$c1"
run
refused "points off its own prefix"
check "nothing installed" nothing_installed

new_case other-host
e="$(entries "$d/serve" "$c1" "$root/bin1" | sed "s|https://files.cmux.com/cmux-tui/$c1/cmux-tui-hook|https://evil.example/cmux-tui/$c1/cmux-tui-hook|")"
payload "$d/p" "$c1" 20261101000000 "$later" "$e"
publish "$d/p" "$c1"
run
refused "points off its own prefix"

new_case lower-sequence
payload "$d/p" "$c2" 20261102000000 "$later" "$(entries "$d/serve" "$c2" "$root/bin2")"
publish "$d/p" "$c2"
run
check "the newer build installs (rc $rc): $(cat "$d/err")" test "$rc" = 0
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
run
refused "is older (sequence 20261101000000) than the build installed here (20261102000000"
check "the newer build stays" installed_is "$root/bin2"
run --commit "$c1"
check "--commit installs an older build on purpose (rc $rc): $(cat "$d/err")" test "$rc" = 0
check "the asked-for build installed" installed_is "$root/bin1"

new_case expired
payload "$d/p" "$c1" 20261101000000 "$((now - 60))" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
run
refused "expired at"
check "nothing installed" nothing_installed

new_case sha-mismatch
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
head -c 5000 /dev/urandom >"$d/serve/$c1/cmux-tui-$target"
run
refused "not the signed"
check "nothing installed" nothing_installed

new_case wrong-channel
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
sed 's/"channel":"feat-cmux-next"/"channel":"nightly"/' "$d/p" >"$d/p2"
publish "$d/p2" "$c1"
run
refused "is for the channel nightly"

new_case wrong-purpose
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
sed 's/"purpose":"cmux-linux-release"/"purpose":"cmux-cloud-machine-update"/' "$d/p" >"$d/p2"
publish "$d/p2" "$c1"
run
refused "is not a Linux release file"

new_case too-large-file
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
head -c 70000 /dev/zero | tr '\0' ' ' >>"$d/serve/channels/linux-feat-cmux-next.json"
run
refused "larger than 64 KiB"

new_case phase1-then-phase1b
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
run
check "the phase-1 file installs (rc $rc): $(cat "$d/err")" test "$rc" = 0
# Phase 1b: a sequence, a tree_key, URLs under tree/<key>/, and the extra names.
mkdir -p "$d/serve/tree/$tree"
cp "$root/bin3" "$d/serve/tree/$tree/cmux-tui-$target"
cp "$root/hook" "$d/serve/tree/$tree/cmux-tui-hook-$target"
cp "$root/hook" "$d/serve/tree/$tree/cmux-tui-acpmux-$target"
cp "$root/hook" "$d/serve/tree/$tree/cmux-tui-app-host-$target"
e="$(lrf_entry cmux-tui "https://files.cmux.com/cmux-tui/tree/$tree/cmux-tui-$target" "$root/bin3"),$(
  lrf_entry cmux-tui-acpmux "https://files.cmux.com/cmux-tui/tree/$tree/cmux-tui-acpmux-$target" "$root/hook"),$(
  lrf_entry cmux-tui-app-host "https://files.cmux.com/cmux-tui/tree/$tree/cmux-tui-app-host-$target" "$root/hook"),$(
  lrf_entry cmux-tui-hook "https://files.cmux.com/cmux-tui/tree/$tree/cmux-tui-hook-$target" "$root/hook")"
payload "$d/p" "$c3" 20261103000000 "$later" "$e" '"sequence":20261103000005,'
sed "s/}}},\"version\"/}}},\"tree_key\":\"$tree\",\"version\"/" "$d/p" >"$d/p2"
publish "$d/p2" "$c3"
run
check "the phase-1b file installs after it (rc $rc): $(cat "$d/err")" test "$rc" = 0
check "installed the tree's binary" installed_is "$root/bin3"
check "recorded the phase-1b sequence" grep -qF '"sequence":20261103000005' "$d/home/.cmux/installed.json"
# A shared-tree commit's own release.json: an alias naming the tree's URLs.
run --commit "$c3"
check "a shared-tree alias installs by --commit (rc $rc): $(cat "$d/err")" test "$rc" = 0
# A phase-1b tree file whose URL is under another tree is still off its prefix.
sed "s|tree/$tree/cmux-tui-hook|tree/cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd/cmux-tui-hook|" "$d/p2" >"$d/p3"
publish "$d/p3" "$c3"
run
refused "points off its own prefix"

new_case no-openssl-3
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
mkdir -p "$d/oldssl"
printf '#!/bin/sh\necho "OpenSSL 1.1.1w  11 Sep 2023"\n' >"$d/oldssl/openssl"
chmod 755 "$d/oldssl/openssl"
rc=0
env -i HOME="$d/home" PATH="$d/oldssl:$shims:$PATH" TMPDIR="$d/tmp" SHELL=/bin/sh \
  LRT_SERVE="$d/serve" LRT_LOG="$d/log" sh "$root/install-static.sh" >"$d/out" 2>"$d/err" || rc=$?
refused "needs OpenSSL 3"
check "the next: line names the package" sh -c 'tail -n 1 "$1" | grep -q "install OpenSSL 3"' _ "$d/err"
check "nothing installed" nothing_installed

new_case not-published
run --commit "$c2"
refused "is not published"

new_case base-url-refused
rc=0
env -i HOME="$d/home" PATH="$shims:$PATH" TMPDIR="$d/tmp" SHELL=/bin/sh CMUX_DOWNLOAD_BASE_URL=https://evil.example \
  LRT_SERVE="$d/serve" LRT_LOG="$d/log" sh "$root/install-static.sh" >"$d/out" 2>"$d/err" || rc=$?
check "CMUX_DOWNLOAD_BASE_URL refused on Linux (rc $rc)" test "$rc" = 2
check "ends with a next: line" last_is_next

# --system: the signed .deb or .rpm, verified, then handed to the package manager through sudo.
# The shims record what the package manager was given; nothing is installed on this machine.
for tool in sudo apt-get dnf; do
  cat >"$shims/$tool" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >>"$LRT_LOG.pm"
[ "$(basename "$0")" = sudo ] && exec "$@"
for a; do :; done
cp "$a" "$LRT_LOG.pkg"
EOF
done
printf '#!/bin/sh\nexit 0\n' >"$shims/dpkg"
chmod 755 "$shims/sudo" "$shims/apt-get" "$shims/dnf" "$shims/dpkg"
# A PATH with no apt-get or dpkg (this machine's included): the rpm path.
nodeb="$root/nodeb"
mkdir -p "$nodeb"
for f in /usr/local/bin/* /usr/bin/* /bin/*; do
  case "${f##*/}" in apt-get | dpkg) continue ;; esac
  [ -e "$nodeb/${f##*/}" ] || ln -s "$f" "$nodeb/${f##*/}" 2>/dev/null || :
done
for tool in sudo dnf curl uname; do ln -sf "$shims/$tool" "$nodeb/$tool"; done
head -c 3000 /dev/urandom >"$root/deb"
head -c 3500 /dev/urandom >"$root/rpm"
# DIR COMMIT: the binaries' entries and the commit's .deb and .rpm.
packaged() {
  mkdir -p "$1/$2"
  cp "$root/deb" "$1/$2/cmux-20261101000000-amd64.deb"
  cp "$root/rpm" "$1/$2/cmux-20261101000000-x86_64.rpm"
  printf '%s,%s,%s' "$(entries "$1" "$2" "$root/bin1")" \
    "$(lrf_entry deb "https://files.cmux.com/cmux-tui/$2/cmux-20261101000000-amd64.deb" "$root/deb")" \
    "$(lrf_entry rpm "https://files.cmux.com/cmux-tui/$2/cmux-20261101000000-x86_64.rpm" "$root/rpm")"
}
pm_got() { cmp -s "$d/log.pkg" "$1"; }
no_pm() { [ ! -e "$d/log.pm" ]; }

new_case system-deb
payload "$d/p" "$c1" 20261101000000 "$later" "$(packaged "$d/serve" "$c1")"
publish "$d/p" "$c1"
run --system
check "--system installs the .deb (rc $rc): $(cat "$d/err")" test "$rc" = 0
check "apt-get was given the signed .deb" pm_got "$root/deb"
check "through sudo: $(cat "$d/log.pm" 2>/dev/null)" grep -q '^sudo apt-get install -y /' "$d/log.pm"
check "nothing in ~/.cmux/bin" nothing_installed
check "downloaded only the pointer and the .deb: $(cat "$d/log")" \
  test "$(grep -vc -e '/channels/linux-feat-cmux-next.json$' -e "/$c1/cmux-20261101000000-amd64.deb\$" -e install-events "$d/log")" = 0

new_case system-rpm
payload "$d/p" "$c1" 20261101000000 "$later" "$(packaged "$d/serve" "$c1")"
publish "$d/p" "$c1"
rc=0
env -i HOME="$d/home" PATH="$nodeb" TMPDIR="$d/tmp" SHELL=/bin/sh \
  LRT_SERVE="$d/serve" LRT_LOG="$d/log" sh "$root/install-static.sh" --system >"$d/out" 2>"$d/err" || rc=$?
check "--system installs the .rpm without apt-get (rc $rc): $(cat "$d/err")" test "$rc" = 0
check "dnf was given the signed .rpm" pm_got "$root/rpm"
check "through sudo: $(cat "$d/log.pm" 2>/dev/null)" grep -q '^sudo dnf install -y /' "$d/log.pm"

new_case system-no-package
payload "$d/p" "$c1" 20261101000000 "$later" "$(entries "$d/serve" "$c1" "$root/bin1")"
publish "$d/p" "$c1"
run --system
refused "names no .deb for $target"
check "the package manager was not run" no_pm
check "nothing installed" nothing_installed

new_case system-sha-mismatch
payload "$d/p" "$c1" 20261101000000 "$later" "$(packaged "$d/serve" "$c1")"
publish "$d/p" "$c1"
head -c 3000 /dev/urandom >"$d/serve/$c1/cmux-20261101000000-amd64.deb"
run --system
refused "not the signed"
check "the package manager was not run" no_pm

new_case system-not-a-deb
e="$(packaged "$d/serve" "$c1" | sed "s|cmux-20261101000000-amd64.deb|cmux-tui-$target|")"
payload "$d/p" "$c1" 20261101000000 "$later" "$e"
publish "$d/p" "$c1"
run --system
refused "not a cmux .deb"
check "the package manager was not run" no_pm

new_case system-dry-run
run --system --dry-run
check "--system --dry-run exits 0 (rc $rc): $(cat "$d/err")" test "$rc" = 0
check "names the package manager: $(cat "$d/out")" grep -q 'apt-get install -y' "$d/out"
check "the package manager was not run" no_pm

printf 'linux-release-verify.test.sh: %d passed, %d failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
