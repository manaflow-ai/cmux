#!/bin/sh
# Runs INSIDE a linux/386 Alpine container started by scripts/bake-ish-rootfs.sh.
# Installs the cmux local Linux tool set, applies the cmux profile, and writes
# /out/rootfs.tar.gz plus /out/packages.json describing the result.
#
# The image is the base every iPhone gets. Node.js and pi are not baked in:
# they add about 55 MB compressed, so `cmux-linux add node` installs them on
# demand from the Alpine mirror and npm.
set -eu

: "${CMUX_ROOTFS_IMAGE_VERSION:?set by bake-ish-rootfs.sh}"
: "${CMUX_ROOTFS_PI_PACKAGE:?set by bake-ish-rootfs.sh}"

apk update
# busybox already provides the core userland (including less and tar). bash
# is the interactive shell. ncurses-terminfo-base carries xterm-256color, the
# TERM cmux advertises.
apk add --no-cache \
    bash ncurses-terminfo-base tree jq \
    git openssh-client-default curl ca-certificates \
    python3 py3-pip \
    vim nano tmux ripgrep

# Root logs in through busybox `login -f root`, which execs the passwd shell.
sed -i 's#^root:\(.*\):/bin/ash$#root:\1:/bin/bash#; s#^root:\(.*\):/bin/sh$#root:\1:/bin/bash#' /etc/passwd
grep -q '^root:.*:/bin/bash$' /etc/passwd

install -d /etc/cmux
printf '%s\n' "$CMUX_ROOTFS_IMAGE_VERSION" > /etc/cmux/image-version
printf '%s\n' "$CMUX_ROOTFS_PI_PACKAGE" > /etc/cmux/pi-package
printf 'iphone\n' > /etc/hostname

# busybox init reads this. The stock inittab runs openrc (not installed) and six
# gettys on consoles iSH does not have, so it would respawn failing processes
# under emulation forever. Keep init alive as PID 1 and do nothing else.
cat > /etc/inittab <<'INITTAB'
::sysinit:/sbin/cmux-sysinit
::shutdown:/bin/true
INITTAB
cat > /sbin/cmux-sysinit <<'SYSINIT'
#!/bin/sh
hostname -F /etc/hostname 2>/dev/null || true
SYSINIT
chmod 755 /sbin/cmux-sysinit

# busybox login keeps only TERM from the caller environment, so the shell
# environment is defined here rather than by the iOS host.
cat > /etc/profile.d/cmux.sh <<'PROFILE'
export COLORTERM=truecolor
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export EDITOR=vim
export PAGER=less
export PIP_BREAK_SYSTEM_PACKAGES=1
export NPM_CONFIG_UPDATE_NOTIFIER=false
if [ -n "${BASH_VERSION:-}" ]; then
    PS1='\[\e[1;32m\]\u@iphone\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
fi
PROFILE

cat > /etc/motd <<'MOTD'
cmux Linux on this iPhone (Alpine Linux, 32-bit x86 via iSH)
Installed: bash git ssh curl python3 pip vim nano tmux rg jq
Node.js + pi:  cmux-linux add node        More: apk add <package>
MOTD

# Optional tool sets installed on demand, so the app stays small.
cat > /usr/local/bin/cmux-linux <<'CMUXLINUX'
#!/bin/sh
# cmux-linux: manage optional tool sets in cmux's Linux on this iPhone.
set -eu
usage() {
    cat <<'USAGE'
usage: cmux-linux <command>
  add node      Install Node.js, npm, and the pi coding agent (about 55 MB)
  status        Show the image version and installed tool sets
USAGE
}
pi_package() { cat /etc/cmux/pi-package; }
case "${1:-}" in
    add)
        case "${2:-}" in
            node)
                if command -v node >/dev/null 2>&1 && [ ! -e /usr/local/bin/.node-stub ]; then
                    echo "Node.js is already installed: $(node --version)"
                else
                    echo "Installing Node.js and npm from the Alpine mirror..."
                    apk add --no-cache nodejs npm
                    rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/.node-stub
                fi
                if command -v pi >/dev/null 2>&1 && [ ! -e /usr/local/bin/.pi-stub ]; then
                    echo "pi is already installed: $(pi --version)"
                else
                    echo "Installing pi ($(pi_package)) with npm..."
                    rm -f /usr/local/bin/pi /usr/local/bin/.pi-stub
                    npm install -g "$(pi_package)" --no-audit --no-fund
                fi
                echo "Done. Run: pi"
                ;;
            *) usage >&2; exit 64 ;;
        esac
        ;;
    status)
        echo "image: $(cat /etc/cmux/image-version)"
        if [ -e /usr/local/bin/.node-stub ]; then echo "node: not installed (cmux-linux add node)"; else echo "node: $(node --version 2>/dev/null || echo unavailable)"; fi
        if [ -e /usr/local/bin/.pi-stub ]; then echo "pi: not installed (cmux-linux add node)"; else echo "pi: $(pi --version 2>/dev/null || echo unavailable)"; fi
        ;;
    *) usage >&2; exit 64 ;;
esac
CMUXLINUX
chmod 755 /usr/local/bin/cmux-linux

# Stubs answer "not installed yet" with the install command instead of
# "command not found". `cmux-linux add node` replaces them.
for tool in node npm npx pi; do
    cat > "/usr/local/bin/$tool" <<STUB
#!/bin/sh
echo "$tool is not installed yet. Install Node.js and pi (about 55 MB) with:" >&2
echo "    cmux-linux add node" >&2
exit 127
STUB
    chmod 755 "/usr/local/bin/$tool"
done
touch /usr/local/bin/.node-stub /usr/local/bin/.pi-stub

# Native agents ship only x86_64 and arm64 builds. Give a clear answer instead
# of "command not found" and point at the hosts that can run them.
for tool in claude codex opencode; do
    cat > "/usr/local/bin/$tool" <<STUB
#!/bin/sh
cat >&2 <<'MSG'
$tool is not available on this iPhone's Linux.
This environment is 32-bit x86 (iSH). $tool ships only 64-bit builds.
Hold the + button in cmux and pick a Mac to run $tool there.
pi runs locally:  cmux-linux add node   then   pi
MSG
exit 69
STUB
    chmod 755 "/usr/local/bin/$tool"
done

# Trim bytes that do not change behavior. Keep plain .pyc so first imports do
# not recompile the stdlib under emulation; drop the optimized variants.
find /usr/lib/python3.* -name '*.opt-1.pyc' -delete -o -name '*.opt-2.pyc' -delete
rm -rf /usr/lib/python3.*/test /usr/lib/python3.*/idlelib /usr/lib/python3.*/turtledemo \
    /usr/lib/python3.*/tkinter /usr/lib/python3.*/ensurepip
# vim runtime: keep syntax, ftplugin, indent, colors, autoload, plugin.
for dir in /usr/share/vim/vim*/; do
    rm -rf "$dir/doc" "$dir/tutor" "$dir/lang" "$dir/spell" "$dir/print" "$dir/tools" \
        "$dir/macros" "$dir/pack" "$dir/keymap" "$dir/compiler"
done
rm -rf /usr/share/man /usr/share/doc /usr/share/info /var/cache/apk/* /root/.cache /tmp/*

# Sanity: every advertised command resolves and the stubs are in place.
for cmd in bash git ssh curl python3 pip vim nano tmux rg jq tree cmux-linux; do
    command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 1; }
done
python3 -c 'import ssl, sqlite3, json; print("python ok")'
git --version
cmux-linux status

python3 - <<'PY'
import json
pkgs = []
cur = {}
def flush():
    if cur:
        pkgs.append({"name": cur.get("P"), "version": cur.get("V"), "license": cur.get("L")})
for line in open("/lib/apk/db/installed", encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        flush(); cur = {}
        continue
    key, _, value = line.partition(":")
    if key in ("P", "V", "L"):
        cur[key] = value
flush()
pkgs.sort(key=lambda p: p["name"])
out = {
    "alpine_release": open("/etc/alpine-release").read().strip(),
    "packages": pkgs,
    "optional_tool_sets": {
        "node": {
            "install": "cmux-linux add node",
            "apk_packages": ["nodejs", "npm"],
            "npm_packages": [open("/etc/cmux/pi-package").read().strip()],
        }
    },
}
json.dump(out, open("/out/packages.json", "w"), indent=2)
PY

cd /
tar --numeric-owner --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./out \
    --exclude=./tmp --exclude=./run --exclude=./bake -czf /out/rootfs.tar.gz .
du -sm /usr /lib /etc /root | sort -n
ls -la /out
