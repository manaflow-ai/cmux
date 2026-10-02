#!/bin/sh
# Headless Chromium for the browser role (server.md 10): chrome-headless-shell
# from the Chrome for Testing JSON at a pinned version, run as the non-root
# server user WITH the sandbox. Never falls back to --no-sandbox.
#   chromium.sh <dir>     (run as the server user)
set -eu
VERSION=${CHS_VERSION:-154.0.8037.92}
dir=${1:-$HOME/chs}
json=https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json
mkdir -p "$dir"
cd "$dir"
url=$(curl -fsSL "$json" | python3 -c '
import json, sys
v = sys.argv[1]
for e in json.load(sys.stdin)["versions"]:
    if e["version"] == v:
        for d in e["downloads"].get("chrome-headless-shell", []):
            if d["platform"] == "linux64":
                print(d["url"])' "$VERSION")
[ -n "$url" ] || { echo "version $VERSION has no linux64 chrome-headless-shell"; exit 1; }
echo "url=$url"
curl -fsSL --proto '=https' -o chs.zip "$url"
echo "zip_sha256=$(sha256sum chs.zip | awk '{print $1}') size=$(wc -c <chs.zip)"
rm -rf chrome-headless-shell-linux64
python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(".")' chs.zip
chmod 755 chrome-headless-shell-linux64/chrome-headless-shell chrome-headless-shell-linux64/chrome_crashpad_handler 2>/dev/null || true
bin="$dir/chrome-headless-shell-linux64/chrome-headless-shell"
echo "binary_sha256=$(sha256sum "$bin" | awk '{print $1}')"
"$bin" --version 2>&1 | head -n 1
echo "--- kernel and LSM facts"
for k in kernel.apparmor_restrict_unprivileged_userns kernel.unprivileged_userns_clone user.max_user_namespaces; do
  printf '  %s = %s\n' "$k" "$(sysctl -n "$k" 2>&1)"
done
printf '  apparmor enabled = %s; lsm = %s\n' "$(cat /sys/module/apparmor/parameters/enabled 2>&1)" "$(cat /sys/kernel/security/lsm 2>&1)"
printf '  unshare -Ur: %s\n' "$(unshare -Ur id -u 2>&1)"
cat >page.html <<'HTML'
<!doctype html><title>cmux server</title><p id=x>static</p><script>document.getElementById('x').textContent='js ran ' + (6*7)</script>
HTML
ud=$(mktemp -d)
t0=$(date +%s%3N)
"$bin" --headless --disable-gpu --user-data-dir="$ud" --dump-dom "file://$dir/page.html" >dom-local.txt 2>err-local.txt
rc=$?
echo "local dump rc=$rc ms=$(($(date +%s%3N) - t0)): $(tr -d '\n' <dom-local.txt | head -c 200)"
t0=$(date +%s%3N)
"$bin" --headless --disable-gpu --user-data-dir="$ud" --dump-dom https://example.com >dom-remote.txt 2>err-remote.txt
rc2=$?
echo "example.com dump rc=$rc2 ms=$(($(date +%s%3N) - t0)): $(grep -o '<h1[^>]*>[^<]*</h1>' dom-remote.txt | head -n 1)"
grep -iE 'sandbox|namespace|zygote' err-local.txt err-remote.txt | head -n 5 | sed 's/^/  stderr| /' || true
# Prove the renderer is sandboxed: start a pipe-mode browser on a page and
# read each renderer's namespaces and seccomp mode while it runs.
fifo="$ud/devtools.in"
mkfifo "$fifo"
"$bin" --headless --disable-gpu --user-data-dir="$ud" --remote-debugging-pipe "file://$dir/page.html" 3<>"$fifo" 4>/dev/null 2>/dev/null &
bpid=$!
i=0
# Bounded wait for the renderer process to appear (test harness only).
until pgrep -f -- '--type=renderer' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || break
  sleep 0.1
done
for r in $(pgrep -f -- '--type=renderer' | head -n 2); do
  printf '  renderer %s: seccomp=%s userns=%s (browser userns=%s) pidns=%s (browser pidns=%s) netns_differs=%s\n' "$r" \
    "$(awk '/^Seccomp:/ {print $2}' /proc/"$r"/status)" \
    "$(readlink /proc/"$r"/ns/user)" "$(readlink /proc/"$bpid"/ns/user)" \
    "$(readlink /proc/"$r"/ns/pid)" "$(readlink /proc/"$bpid"/ns/pid)" \
    "$([ "$(readlink /proc/"$r"/ns/net)" != "$(readlink /proc/"$bpid"/ns/net)" ] && echo yes || echo no)"
done
kill "$bpid" 2>/dev/null || true
wait "$bpid" 2>/dev/null || true
rm -rf "$ud"
if [ "$rc" = 0 ] && grep -q 'js ran 42' dom-local.txt && [ "$rc2" = 0 ] && grep -q 'Example Domain' dom-remote.txt; then
  echo "RESULT chromium PASS sandboxed headless shell dumped local and remote DOM as $(id -un)"
else
  echo "RESULT chromium FAIL rc=$rc rc2=$rc2"
  tail -n 5 err-local.txt
fi
