#!/usr/bin/env bash
# process-model-census.py (p01-process task 004): a canned census directory (ps.txt, threads.txt,
# memory.txt, samples.txt, session.json) gives every role its processes by executable path and owner,
# leaves another tag's processes and the user's shells out, folds thread names, takes peaks from the
# samples, counts a ring shared by the holder and a VT worker once, and checks names and QoS against a
# thread doc. Then one live census of this shell (Linux /proc or macOS libproc). Portable, no app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CENSUS="$ROOT_DIR/scripts/cmux-next/process-model-census.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-process-census.XXXXXX")"
sleeper=""
trap '[[ -n "$sleeper" ]] && kill "$sleeper" 2>/dev/null; rm -rf "$tmp"' EXIT

B="/Applications/cmux DEV t1.app"
B2="/Applications/cmux DEV t2.app"
HX="/Users/u/Library/Application Support/cmux-tui/host-exe"
dir="$tmp/canned"
mkdir -p "$dir"
cat > "$dir/ps.txt" <<EOF
    1     0   1000 /sbin/launchd
  100     1 400000 $B/Contents/MacOS/cmux DEV
  101   100  80000 $B/Contents/Frameworks/cmux DEV Helper (GPU).app/Contents/MacOS/cmux DEV Helper (GPU) --type=gpu-process
  102     1  60000 $B/Contents/Resources/bin/cmux-tui --headless --session cmux-app-t1 --socket /tmp/t1.sock
  104     1  40000 $B/Contents/Resources/bin/cmux-tui --headless --session cmux-chief --socket /tmp/chief.sock
  110     1   5000 $HX/abc/cmux-holder --owner cmux_DEV_t1:t1@102
  111   110   2000 /bin/zsh -l
  120     1   3000 $HX/def/cmux-tui-host __terminal-host --bootstrap-stdio --owner cmux_DEV_t1:t1@99
  121   120   2000 /bin/zsh -l
  122   102   3000 $HX/def/cmux-tui-host __terminal-host --bootstrap-stdio
  130   110   4000 $HX/aaa/cmux-vt-worker --shard 0
  131   110   4000 $HX/aaa/cmux-vt-worker --shard 1
  140   100  90000 $B/Contents/MacOS/cmux DEV Chromium Host --data x
  141   140  50000 $B/Contents/Frameworks/cmux DEV Helper (Renderer).app/Contents/MacOS/cmux DEV Helper (Renderer) --type=renderer
  142   140  50000 $B/Contents/Frameworks/cmux DEV Helper (Renderer).app/Contents/MacOS/cmux DEV Helper (Renderer) --type=renderer
  150   100   7000 $B/Contents/Resources/bin/acpmux serve
  151   100   3000 $B/Contents/Resources/bin/cmux --app-socket /tmp/cmux-debug-t1.sock --json workspace list
  152   100   3000 $B/Contents/Resources/bin/cmux-tui link serve --state-dir /tmp/link
  200     1 100000 $B2/Contents/MacOS/cmux DEV
  201     1   3000 $HX/def/cmux-tui-host __terminal-host --bootstrap-stdio --owner cmux_DEV_t2:t2@202
  202     1   6000 $B2/Contents/Resources/bin/cmux-tui --session cmux-app-t2 server run
EOF
# proc_pidpath reads the resolved file: bin/cmux-tui is a symlink to bin/cmux, argv keeps cmux-tui.
printf '%s\n' $'102\t'"$B/Contents/Resources/bin/cmux" $'104\t'"$B/Contents/Resources/bin/cmux" \
  $'151\t'"$B/Contents/Resources/bin/cmux" $'152\t'"$B/Contents/Resources/bin/cmux" > "$dir/exe.txt"
printf '%s\n' \
  $'102\tuser-initiated\tmux-seq-control' $'102\tuser-initiated\tmux-seq-control' $'102\tdefault\tsurface-12-reader' \
  $'102\tdefault\tsurface-13-reader' $'102\tdefault\tmain' $'110\tuser-initiated\tholder-link' \
  $'100\tuser-interactive\t' $'100\tdefault\t' $'100\tuser-interactive\tcmux-next main-thread watchdog' \
  $'100\tutility\tcom.cmuxterm.next.terminal.output' $'100\tdefault\tcom.apple.NSEventThread' \
  $'140\tdefault\tcom.cmuxterm.chromium-host.read' $'140\tuser-initiated\tChrome_IOThread' \
  $'141\tdefault\tThreadPoolForegroundWorker' $'111\tdefault\t' $'200\tdefault\tcmux-next main-thread watchdog' \
  > "$dir/threads.txt"
printf '%s\n' \
  $'100\t300000\t200000\tsurface:2048' $'110\t4000\t3000\tring1:1024,ring2:1024' $'130\t3000\t2000\tring1:1024' \
  $'131\t3000\t2000\tring2:1024' $'120\t2000\t1500\t' $'122\t2000\t1500\t' $'102\t50000\t40000\t' \
  $'140\t80000\t60000\tsurface:2048' $'111\t1000\t1000\t' $'101\t12000\t10000\t' $'141\t25000\t20000\t' \
  $'142\t25000\t20000\t' $'150\t6000\t5000\t' $'151\t2000\t1000\t' $'152\t2000\t1000\t' > "$dir/memory.txt"
# A daemon restart: the old daemon's threads grow, then the next daemon (103) starts with 20.
printf '%s\t%s\t1\t%s\t%s\n' \
  0 100 5 "$B/Contents/MacOS/cmux DEV" 0 102 5 "$B/Contents/Resources/bin/cmux-tui server run" \
  1 100 6 "$B/Contents/MacOS/cmux DEV" 1 102 10 "$B/Contents/Resources/bin/cmux-tui server run" \
  2 100 6 "$B/Contents/MacOS/cmux DEV" 2 103 20 "$B/Contents/Resources/bin/cmux-tui server run" \
  > "$dir/samples.txt"
cat > "$dir/session.json" <<EOF
{"bundle": "$B", "tag": "t1", "terminals": 5, "hidden_terminals": 4, "host": "fixture", "os": "Darwin 25"}
EOF

python3 -I "$CENSUS" --from "$dir" --json --out "$tmp/census.json" > "$tmp/stdout.json"
python3 -I - "$tmp/census.json" "$tmp/stdout.json" <<'EOF'
import json, sys
report = json.load(open(sys.argv[1]))
assert report == json.load(open(sys.argv[2])), "--out and --json differ"
roles = report["roles"]
def eq(what, got, want):
    assert got == want, f"{what}: {got!r}, want {want!r}"
for role in ("app", "daemon", "holder", "vt_worker", "terminal_host", "chromium_host", "chromium_helper"):
    for key in ("processes", "threads", "rss_mb", "peak_threads"):
        assert key in roles[role], f"roles.{role}.{key} missing"
eq("app pid", report["app_pid"], 100)
# The daemon by its resolved binary (bin/cmux) and owner argv; the Chief daemon (ppid 1) is not counted, a CLI
# call and the cloud link under the app are `other`.
want = {"app": [100], "daemon": [102], "holder": [110], "vt_worker": [130, 131], "terminal_host": [120, 122],
        "chromium_host": [140], "chromium_helper": [101, 141, 142], "other": [150, 151, 152]}
for role, pids in want.items():
    eq(f"{role} pids", roles[role]["pids"], pids)
eq("children", report["children"]["processes"], 2)
eq("another tag's host", report["foreign_hosts"], 1)
eq("daemon threads", roles["daemon"]["threads"], 5)
eq("daemon peak (the next daemon during the restart)", roles["daemon"]["peak_threads"], 20)
eq("app peak (sampled above now)", roles["app"]["peak_threads"], 6)
eq("daemon names", roles["daemon"]["threads_by_name"], {"mux-seq-control": 2, "surface-<n>-reader": 2, "main": 1})
eq("daemon qos", roles["daemon"]["threads_by_qos"], {"default": 3, "user-initiated": 2})
eq("app unnamed", roles["app"]["threads_by_name"]["<unnamed>"], 2)
eq("rss", roles["vt_worker"]["rss_mb"], round(8000 / 1024, 1))
eq("folded name over roles", report["threads_by_name"]["surface-<n>-reader"], {"count": 2, "roles": {"daemon": 2}, "qos": {"default": 2}})
assert "cmux-next main-thread watchdog" in report["threads_by_name"]
eq("other tag's app not counted", report["threads_by_name"]["cmux-next main-thread watchdog"]["count"], 1)
eq("per-object threads", report["per_object_threads"], {"surface-<n>-reader": 2})
eq("threads excluding helpers", report["totals"]["cmux_threads_excluding_helpers"], 13)
# The holder and the VT workers map the same two rings: each counts once.
eq("terminal roles shared", roles["vt_worker"]["shared_mb"], 2.0)
terminal_kb = 3000 + 2000 + 2000 + 1500 + 1500 + 2048
# No baseline: no per-hidden-terminal figure; the terminal roles' memory under its own name.
eq("per hidden terminal without a baseline", report["per_hidden_terminal_mb"], None)
assert report["per_hidden_terminal_basis"].startswith("no baseline"), report["per_hidden_terminal_basis"]
eq("terminal roles memory", report["terminal_roles_unique_mb"], round(terminal_kb / 1024, 1))
eq("memory read in full", report["memory"]["regions_missing_pids"], [])
private = 200000 + 3000 + 2000 + 2000 + 1500 + 1500 + 40000 + 60000 + 10000 + 20000 + 20000 + 5000 + 1000 + 1000
eq("unique (rings and the surface once)", report["totals"]["unique_mb"], round((private + 2048 + 2048) / 1024, 1))
eq("shared objects", report["totals"]["shared_objects"], 3)
EOF

# A baseline census of the same build: growth over it, all roles.
printf '{"session": {"hidden_terminals": 0}, "totals": {"unique_mb": 300.0}}\n' > "$tmp/base.json"
python3 -I "$CENSUS" --from "$dir" --json --baseline "$tmp/base.json" > "$tmp/delta.json"
python3 -I - "$tmp/delta.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
want = round((r["totals"]["unique_mb"] - 300.0) / 4, 2)
assert abs(r["per_hidden_terminal_mb"] - want) <= 0.05, (r["per_hidden_terminal_mb"], want)
assert r["per_hidden_terminal_basis"].startswith("all roles"), r["per_hidden_terminal_basis"]
EOF

# The thread doc: listed names pass, `<x>` is a wildcard, Chromium's and AppKit's names are not judged,
# an unlisted cmux name and a QoS that differs from the doc fail (exit 1).
cat > "$tmp/doc.md" <<'EOF'
# threads
## Registered threads and queues
- `cmux-next main-thread watchdog`, `com.cmuxterm.chromium-host.read` (user-initiated), `mux-seq-control` (user-initiated),
  `surface-<id>-reader`, `<pid>`
## Reviewed blocking allowances
- `holder-link`
EOF
code=0
python3 -I "$CENSUS" --from "$dir" --json --check-thread-doc "$tmp/doc.md" > "$tmp/doc.json" || code=$?
[[ $code -eq 1 ]] || { echo "FAIL: --check-thread-doc must exit 1 on an unlisted name (got $code)" >&2; exit 1; }
python3 -I - "$tmp/doc.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))["thread_doc"]
names = sorted(i["name"] for i in doc["unlisted"])
assert names == ["com.cmuxterm.next.terminal.output", "holder-link", "main"], names
assert doc["qos_mismatch"] == [{"name": "com.cmuxterm.chromium-host.read", "doc": "user-initiated",
                                "observed": {"default": 1}}], doc["qos_mismatch"]
EOF
printf '%s\n' '## Registered threads and queues' \
  '- `cmux-next main-thread watchdog`, `com.cmuxterm.chromium-host.read`, `mux-seq-control` (user-initiated),' \
  '  `surface-<id>-reader`, `main`, `holder-link`, `com.cmuxterm.next.terminal.output`' > "$tmp/doc-ok.md"
python3 -I "$CENSUS" --from "$dir" --check-thread-doc "$tmp/doc-ok.md" > "$tmp/doc-ok.txt" \
  || { echo "FAIL: a doc that lists every name must pass" >&2; cat "$tmp/doc-ok.txt" >&2; exit 1; }
# The repo's own doc parses (its result is the measurement, not this test's).
code=0
python3 -I "$CENSUS" --from "$dir" --check-thread-doc >/dev/null || code=$?
[[ $code -le 1 ]] || { echo "FAIL: threading-model.md did not parse (exit $code)" >&2; exit 1; }

# Text output: the role table and the by-name thread table.
python3 -I "$CENSUS" --from "$dir" --threads --by-name > "$tmp/text.txt"
grep -q '^terminal_host ' "$tmp/text.txt" || { echo "FAIL: no terminal_host row" >&2; cat "$tmp/text.txt" >&2; exit 1; }
grep -q 'surface-<n>-reader' "$tmp/text.txt" || { echo "FAIL: no folded thread name" >&2; exit 1; }

# --dump writes a census directory that reads back to the same census.
python3 -I "$CENSUS" --from "$dir" --json --dump "$tmp/again" > /dev/null
python3 -I "$CENSUS" --from "$tmp/again" --json > "$tmp/again.json"
python3 -I - "$tmp/census.json" "$tmp/again.json" <<'EOF'
import json, sys
a, b = (json.load(open(path)) for path in sys.argv[1:])
assert a["roles"] == b["roles"] and a["totals"] == b["totals"], "a dumped census reads back differently"
assert b["roles"]["daemon"]["pids"] == [102], b["roles"]["daemon"]["pids"]
EOF
grep -q $'^102\t.*/bin/cmux$' "$tmp/again/exe.txt" || { echo "FAIL: --dump lost the executable paths" >&2; exit 1; }

# A region walk that did not run (`-`) or a process with no memory row: the sums are null, never partial.
partial="$tmp/partial"
cp -R "$dir" "$partial"
grep -v $'^150\t' "$dir/memory.txt" | sed $'s/^130\t3000\t2000\t/130\t3000\t-\t/' > "$partial/memory.txt"
python3 -I "$CENSUS" --from "$partial" --json --baseline "$tmp/base.json" > "$tmp/partial.json"
python3 -I - "$tmp/partial.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
roles = r["roles"]
assert roles["vt_worker"]["unique_mb"] is None and roles["vt_worker"]["private_mb"] is None, roles["vt_worker"]
assert roles["vt_worker"]["footprint_mb"] is not None, roles["vt_worker"]
assert roles["other"]["footprint_mb"] is None and roles["other"]["unique_mb"] is None, roles["other"]
assert roles["daemon"]["unique_mb"] is not None, roles["daemon"]
assert r["totals"]["unique_mb"] is None and r["totals"]["footprint_mb"] is None, r["totals"]
assert r["terminal_roles_unique_mb"] is None, r["terminal_roles_unique_mb"]
assert r["per_hidden_terminal_mb"] is None and r["per_hidden_terminal_basis"].startswith("unknown"), r
assert r["memory"]["regions_missing_pids"] == [130, 150], r["memory"]
assert r["memory"]["footprint_missing_pids"] == [150], r["memory"]
EOF

# A bundle under /tmp: the app and its helpers run from /private/tmp (proc_pidpath), a detached daemon keeps
# the /tmp argv it was given. Either spelling of the bundle finds every role.
for bundle in "/tmp/cmux DEV t3.app" "/private/tmp/cmux DEV t3.app"; do
  priv="$tmp/private"
  rm -rf "$priv"
  mkdir -p "$priv"
  T3="/tmp/cmux DEV t3.app"
  cat > "$priv/ps.txt" <<EOF
  300     1 100000 $T3/Contents/MacOS/cmux DEV
  302     1  50000 $T3/Contents/Resources/bin/cmux-tui --headless --session cmux-app-t3
  340   300  50000 $T3/Contents/MacOS/cmux DEV Chromium Host --data x
  341   340  40000 $T3/Contents/Frameworks/cmux DEV Helper (GPU).app/Contents/MacOS/cmux DEV Helper (GPU)
  350   300   3000 $T3/Contents/Resources/bin/acpmux serve
EOF
  printf '%s\n' $'300\t/private'"$T3/Contents/MacOS/cmux DEV" $'302\t/private'"$T3/Contents/Resources/bin/cmux" \
    $'340\t/private'"$T3/Contents/MacOS/cmux DEV Chromium Host" > "$priv/exe.txt"
  printf '{"bundle": "%s", "tag": "t3"}\n' "$bundle" > "$priv/session.json"
  python3 -I "$CENSUS" --from "$priv" --json > "$tmp/private.json"
  python3 -I - "$tmp/private.json" "$bundle" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
got = {role: v["pids"] for role, v in r["roles"].items() if v["pids"]}
want = {"app": [300], "daemon": [302], "chromium_host": [340], "chromium_helper": [341], "other": [350]}
assert got == want, (sys.argv[2], got)
EOF
done

# The repo's threading-model.md lists the Rust daemon's and holder's threads in its owner table.
rust="$tmp/rust"
mkdir -p "$rust"
cat > "$rust/ps.txt" <<EOF
  102     1  60000 $B/Contents/Resources/bin/cmux-tui --headless --session cmux-app-t1 --socket /tmp/t1.sock
  110     1   5000 $HX/abc/cmux-holder --owner cmux_DEV_t1:t1@102
EOF
printf '%s\n' $'102\tdefault\tmux-remote-conn' $'102\tdefault\tmux-server' $'102\tdefault\tmux-session-journal-writer' \
  $'102\tdefault\tmux-session-journal-writer-fanout' $'110\tdefault\tholder-link' > "$rust/threads.txt"
printf '{"bundle": "%s", "tag": "t1"}\n' "$B" > "$rust/session.json"
python3 -I "$CENSUS" --from "$rust" --json --check-thread-doc > "$tmp/rust.json" \
  || { echo "FAIL: threads the owner table lists must pass the repo's doc" >&2; cat "$tmp/rust.json" >&2; exit 1; }
python3 -I - "$tmp/rust.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))["thread_doc"]
assert doc["judged"] == 5 and doc["unlisted"] == [] and doc["qos_mismatch"] == [], doc
EOF
# An owner-table row's QoS cell is compared; `not set` names no class.
printf '%s\n' '| Thread / queue | Owns | QoS |' '|---|---|---|' \
  '| **Daemon** `mux-remote-conn`, `mux-server` | requests | user-initiated |' \
  '| **Journal** `mux-session-journal-writer` (+ `-fanout`) | disk | not set |' \
  '| **Holder** `cmux-holder`, `holder-link` | PTYs | utility (link) |' > "$tmp/table.md"
code=0
python3 -I "$CENSUS" --from "$rust" --json --check-thread-doc "$tmp/table.md" > "$tmp/table.json" || code=$?
[[ $code -eq 1 ]] || { echo "FAIL: a QoS that differs from the owner table must exit 1 (got $code)" >&2; exit 1; }
python3 -I - "$tmp/table.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))["thread_doc"]
assert doc["unlisted"] == [], doc["unlisted"]
assert sorted(m["name"] for m in doc["qos_mismatch"]) == ["holder-link", "mux-remote-conn", "mux-server"], doc["qos_mismatch"]
EOF

# perf-stress-session.py terminal_counts: a terminal shows only as the selected tab of a pane on the shown
# screen (debug.screens active_screen, else the first) of a workspace a visible window shows; a zoomed screen
# shows only its zoomed pane; a dock pane shows with its screen.
python3 -I - "$ROOT_DIR/scripts/cmux-next/perf-stress-session.py" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("perf_stress_session", sys.argv[1])
stress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stress)
def pane(pid, selected, *tabs, dock=None):
    return {"id": pid, "selected_tab": selected, "dock": dock, "tabs": [{"id": t, "kind": k} for t, k in tabs]}
p5 = pane("p5", "b1", ("t6", "terminal"), ("b1", "browser"))
p5["tabs"].append({"id": "pg", "kind": "page", "selected": False})
topology = {
    "windows": [{"key": "w1", "workspace": "ws_a", "visible": True}, {"key": "w2", "workspace": "ws_b", "visible": True},
                {"key": "w3", "workspace": "ws_d", "visible": False}],
    "workspaces": [
        {"id": "ws_a", "key": "k_a", "screens": [
            {"id": "s_a1", "panes": [pane("p1", "t1", ("t1", "terminal"))]},
            {"id": "s_a2", "panes": [pane("p2", "t2", ("t2", "terminal"), ("t3", "terminal")),
                                     pane("p3", "t4", ("t4", "terminal"), dock="left")]}]},
        {"id": "ws_b", "key": "k_b", "screens": [
            {"id": "s_b1", "zoomed_pane": "p5", "panes": [pane("p4", "t5", ("t5", "terminal")), p5]},
            {"id": "s_b2", "panes": [pane("p6", "t7", ("t7", "terminal"))]}]},
        {"id": "ws_c", "screens": [{"id": "s_c1", "panes": [pane("p7", "t8", ("t8", "terminal"))]}]},
        {"id": "ws_d", "screens": [{"id": "s_d1", "panes": [pane("p8", "t9", ("t9", "terminal"))]}]},
    ]}
screens = {"windows": [{"window": "w1", "active_screen": "s_a2"}, {"window": "w2", "active_screen": None}]}
got = stress.terminal_counts(topology, screens)
assert got == {"terminals": 9, "hidden_terminals": 7}, got  # only t2 and t4 show
# Without debug.screens, a shown workspace of several screens leaves the hidden count unknown.
got = stress.terminal_counts(topology)
assert got == {"terminals": 9, "hidden_terminals": None}, got
one = {"windows": [{"key": "w1", "workspace": "ws_c"}], "workspaces": topology["workspaces"][2:3]}
got = stress.terminal_counts(one)
assert got == {"terminals": 1, "hidden_terminals": 0}, got
EOF

# A session that does not build is a census error (exit 2 from main), not a traceback that reads as exit 1.
python3 -I - "$CENSUS" <<'EOF'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("census", sys.argv[1])
census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(census)
class Builder:
    def __init__(self, rpc):
        pass
    def build_heavy(self):
        raise RuntimeError("terminal tab did not appear")
    def close(self):
        pass
census.load_stress = lambda: types.SimpleNamespace(socket_rpc=lambda path: None, Stress=Builder)
try:
    census.build_session("heavy", "/nonexistent.sock")
except census.CensusError as error:
    assert "heavy session did not build" in str(error), error
else:
    raise AssertionError("build_session did not raise")
EOF

# No ps.txt: a usage error (exit 2), not a traceback.
mkdir -p "$tmp/empty"
code=0
python3 -I "$CENSUS" --from "$tmp/empty" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 2 ]] && grep -q 'no ps.txt' "$tmp/err" || { echo "FAIL: a directory without ps.txt must exit 2 (got $code)" >&2; exit 1; }

# Live: this shell as the app role, with a child. Linux reads /proc, macOS libproc.
sleep 30 &
sleeper=$!
python3 -I "$CENSUS" --pid $$ --json > "$tmp/live.json"
python3 -I - "$tmp/live.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
app = r["roles"]["app"]
assert app["processes"] == 1 and app["threads"] >= 1, app
assert app["rss_mb"] and app["rss_mb"] > 0, app
assert r["children"]["processes"] >= 1, r["children"]
EOF
echo "process-model-census: ok"
