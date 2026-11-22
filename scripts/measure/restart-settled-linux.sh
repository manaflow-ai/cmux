#!/usr/bin/env bash
# Restart to settled, the agent chat beside the terminal, per simulated link, in one job (Leo, 2026-11-22: "you guys
# need to be able to simulate the update/restart and the connection speed and what is actually displayed and get
# that gui agent chat sped up to be nearly as fast as the terminal coming back (e.g. my claude code cli,
# interim-coord)").
#
# Chat: webviews/bench/first-load-after-restart.bench.ts MODE=down, the production pane relaunched in a cold
# Chromium context with its saved copy and the host's kept tail, the stand-in acpmux up (ACPMUX_DOWN_MS=0, the
# app restarted and the daemon kept running) or restarting (down=MS), the bridge's socket on LINK. Its
# RESTART_SETTLED_JSON: first content, settled (the live chat shows the newest answer and nothing in view moves
# after), shifts after first content.
# Terminal: cmux-tui/crates/cmux-tui/tests/terminal_restart_settled.rs, the real daemon holding a Claude Code-like
# session's PTY, reattached by a new client the way the Mac app's TerminalAttachment does, on the same link model
# and profiles (webviews/bench/link-profiles.json). Its TERMINAL_RESTART_JSON: first content, settled.
#
#   cmux-ci test --setup rust -- 'scripts/measure/restart-settled-linux.sh [links=local,rtt50,rtt200,throttled]
#     [rounds=5] [turns=120] [down=0] [only=chat|terminal]'
#
# Prints both rows per link and one `RESTART_SETTLED_COMPARE {...}` line: per link, the chat's and the terminal's
# medians and the ratio chat settled / terminal settled. What it does not cover: the native app's process start,
# Chromium's own start, Sparkle, the Ghostty Metal draw and the Swift surface (the terminal row ends at the parsed
# screen); the chat runs in headless Chromium on Linux, not WKWebView or the app's CEF.
set -euo pipefail
links=local,rtt50,rtt200,throttled
rounds=5
turns=120
down=0
only=both
for arg in "$@"; do
  case "$arg" in
    links=*) links="${arg#links=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    turns=*) turns="${arg#turns=}" ;;
    down=*) down="${arg#down=}" ;;
    only=*) only="${arg#only=}" ;;
    *) echo "restart-settled-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# Chromium's singleton socket path must fit a unix socket's 108 bytes.
export TMPDIR="$out"
status=0

if [[ "$only" != chat ]]; then
  command -v cargo >/dev/null || "$root/scripts/install-rust-ci.sh"
  export PATH="$HOME/.cargo/bin:$PATH"
  (
    cd "$root/cmux-tui"
    # Every profile in link-profiles.json, 120 turns (the test's own fixture); `links=` and `turns=` pick the chat's.
    RESTART_ATTACH=snapshot ROUNDS="$rounds" cargo test --locked --release -p cmux-tui --test terminal_restart_settled -- --ignored --nocapture
  ) >"$out/terminal.log" 2>&1 || { status=1; echo "restart-settled: the terminal measure failed:"; tail -n 30 "$out/terminal.log"; }
  grep -E "^TERMINAL_RESTART_JSON " "$out/terminal.log" || true
fi

if [[ "$only" != terminal ]]; then
  command -v bun >/dev/null || { curl -fsSL https://bun.sh/install | bash -s bun-v1.4.4 >/dev/null; }
  export PATH="$HOME/.bun/bin:$PATH"
  cd "$root/webviews"
  [[ -d node_modules ]] || bun install --frozen-lockfile >/dev/null
  # ensure-system-chrome.sh prints what it did, then `CMUX_CHROME_HEADLESS_SHELL=<path>` as its last line: only that
  # line is taken (the whole output, eval'd, ran its "system Chrome ... at ..." line as a command and exited 127).
  if [[ -z "${CMUX_CHROME_HEADLESS_SHELL:-}" && -x "$root/scripts/ci/ensure-system-chrome.sh" ]]; then
    shell_line="$("$root/scripts/ci/ensure-system-chrome.sh" --optional 2>/dev/null | grep -E '^CMUX_CHROME_HEADLESS_SHELL=' | tail -n 1 || true)"
    [[ -z "$shell_line" ]] || export "$shell_line"
  fi
  IFS=, read -r -a each <<<"$links"
  for link in "${each[@]}"; do
    LINK="$link" MODE=down ROUNDS="$rounds" TURNS="$turns" ACPMUX_DOWN_MS="$down" \
      bun bench/first-load-after-restart.bench.ts >"$out/chat-$link.log" 2>&1 ||
      { status=1; echo "restart-settled: the chat bench failed on $link:"; grep -v BABEL "$out/chat-$link.log" | tail -n 20; }
    grep -E "^RESTART_SETTLED_JSON |^restart split" "$out/chat-$link.log" || true
    # PROFILE=1 or WIRE_TRACE=1 (the bench's knobs, passed through the environment): what they print, too.
    if [[ "${PROFILE:-}" == 1 || "${WIRE_TRACE:-}" == 1 ]]; then
      grep -E "^wire |relaunch long tasks|^  round |profile|^ +[0-9.]+ ms " "$out/chat-$link.log" | head -n 400 || true
    fi
  done
fi

python3 - "$out" <<'PY'
import glob, json, os, sys

out = sys.argv[1]
chat, term = {}, {}
for path in glob.glob(os.path.join(out, "*.log")):
    for line in open(path, errors="replace"):
        for tag, into in (("RESTART_SETTLED_JSON ", chat), ("TERMINAL_RESTART_JSON ", term)):
            if line.startswith(tag):
                row = json.loads(line[len(tag):])
                into[row["link"]] = row
rows = []
for link in sorted(set(chat) | set(term)):
    c, t = chat.get(link, {}), term.get(link, {})
    cs, ts = c.get("settledMs"), t.get("settledMs")
    rows.append({
        "link": link,
        "chatFirstContentMs": c.get("firstContentMs"), "chatSettledMs": cs, "chatShifts": c.get("shifts"),
        "chatShiftPxMax": c.get("shiftPxMax"), "chatBytes": c.get("bytesDown"),
        "terminalFirstContentMs": t.get("firstContentMs"), "terminalSettledMs": ts,
        "terminalChanges": t.get("changesAfterFirst"), "terminalBytes": t.get("bytes"),
        "ratio": round(cs / ts, 2) if cs and ts else None,
    })
print("| link | chat first content ms | chat settled ms | chat shifts | terminal first content ms | terminal settled ms | ratio |")
print("|---|---:|---:|---:|---:|---:|---:|")
fmt = lambda v: "-" if v is None else (f"{v:.0f}" if isinstance(v, float) else str(v))
for r in rows:
    print(f"| {r['link']} | {fmt(r['chatFirstContentMs'])} | {fmt(r['chatSettledMs'])} | {fmt(r['chatShifts'])} | "
          f"{fmt(r['terminalFirstContentMs'])} | {fmt(r['terminalSettledMs'])} | {fmt(r['ratio'])} |")
print("RESTART_SETTLED_COMPARE " + json.dumps({"rows": rows}))
PY
exit "$status"
