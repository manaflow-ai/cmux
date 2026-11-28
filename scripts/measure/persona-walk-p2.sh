# P2, the 2025 persona (cmuxterm-hq docs/dogfood/personas README): Claude Code in terminal tabs, one per git worktree,
# managed by hand. Sourced by persona-walk.sh after p0 (it uses that script's cua, ui, keys, typeln, shell_task, shot,
# step and note helpers, and its scratch $work, $pid and $cli); not run alone.
#
# p2 walks P2 tasks 1 and 2:
#   1. a scratch repo with two worktrees; `claude` in a terminal tab in each (what a fresh person's claude shows, and
#      a STUCK line when it is missing or stops at sign-in, which a fresh HOME always does);
#   2. the background tab asks for the person (the bell and OSC 9 notification Claude Code writes to its terminal
#      when it waits on a permission prompt), the person is in the other tab: the time until the window shows a
#      needs-you mark (an accessibility element naming unread, attention, needs or waiting, read from cua's markdown
#      tree and new against the snapshot before the ask by AX identifier and text), then a click on that mark
#      and a check that the focused terminal is the background tab's worktree (its `pwd`).
# The ask in step 2 is a stand-in for a signed-in Claude's prompt: a fresh HOME has no Claude login, so a real one
# never comes. The stand-in writes exactly the escape sequences a waiting Claude Code writes, so the app's path from
# terminal output to badge is the one a person's Claude exercises.

p2_marks() { # p2_marks LABEL: write the main window's accessibility elements that read as needs-you, one per line
  cua get_window_state "{\"pid\":$pid,\"window_id\":${wid:-0}}" >"$out/p2-state-$1.json" 2>&1
  python3 - "$out/p2-state-$1.json" <<'PY'
import json, re, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
word = re.compile(r"\b(unread|attention|needs (you|input|your)|waiting (for|on) (you|input)|permission)\b", re.I)
def out(index, role, text, ax_id):
    # "ax" (the AX identifier, else role and text) stays the same across snapshots; element_index does not.
    print(json.dumps({"key": "element_index", "id": index, "role": role, "ax": ax_id or f"{role}:{text}",
                      "text": text.strip()[:160]}, sort_keys=True))
# cua-driver answers a markdown tree (tree_format "markdown"), one element a line:
#   - [3] AXRadioButton (/tmp/x/p2-wt-b, Unread) [id=cmux.tabs.tab.tab_e650... help="/tmp/x/p2-wt-b" actions=[...]]
line = re.compile(r'^\s*- (?:\[(\d+)\] )?(AX\w+)(?: "([^"]*)")?(?: \(([^)]*)\))?(.*)$')
for raw in (doc.get("tree_markdown") or "").splitlines():
    m = line.match(raw)
    if not m:
        continue
    index, role, title, label, rest = m.groups()
    ax_id = (re.search(r"\bid=(\S+)", rest) or [None, None])[1]
    help_ = (re.search(r'\bhelp="([^"]*)"', rest) or [None, ""])[1]
    text = " ".join(x for x in (title, label, help_) if x)
    if index is not None and word.search(text):
        out(int(index), role, text, ax_id)
# Older drivers answered JSON elements.
def walk(v):
    if isinstance(v, dict):
        if isinstance(v.get("role"), str):
            yield v
        for c in v.values():
            yield from walk(c)
    elif isinstance(v, list):
        for c in v:
            yield from walk(c)
for e in walk({k: v for k, v in doc.items() if k != "tree_markdown"}):
    text = " ".join(str(e.get(k) or "") for k in ("label", "name", "title", "description", "value", "help"))
    if e.get("element_index") is not None and word.search(text):
        out(e["element_index"], e.get("role"), text, e.get("identifier"))
PY
}
p2_mark_keys() { # stdin p2_marks lines -> "AX-KEY<tab>TEXT", what compares across snapshots
  python3 -c 'import json,sys
for l in sys.stdin:
    if l.strip(): d=json.loads(l); print(d["ax"]+"\t"+d["text"])'; }

p2() {
  local repo="$work/p2-repo" t a b
  git init -q "$repo" && git -C "$repo" -c user.email=p@x -c user.name=persona commit -q --allow-empty -m init &&
    git -C "$repo" worktree add -q "$work/p2-wt-a" -b wt-a && git -C "$repo" worktree add -q "$work/p2-wt-b" -b wt-b ||
    { note "FAIL p2 scratch repo"; return 1; }
  # Task 1: claude in two tabs, one per worktree. The tab's shell is the app's, so `command -v` is what the person has.
  main_window p2; keys ctrl '`'; sleep_s 1; main_window p2-a
  shell_task p2_tab_a 10 "cd $work/p2-wt-a && (command -v claude || echo no-claude) >$work/p2-claude-path" || return 0
  note "p2 claude on the tab's PATH: $(cat "$work/p2-claude-path" 2>/dev/null)"
  if grep -q no-claude "$work/p2-claude-path" 2>/dev/null; then
    note "STUCK p2 claude: not on the terminal's PATH (a P2 person installs it first; the app offered no path)"
  else
    typeln "claude"; sleep_s 6; shot 20-p2-claude-a
    # A fresh HOME has no Claude login: what claude shows first is the finding (sign-in, theme picker, trust prompt).
    note "STUCK p2 claude: a fresh profile's claude stops at its own first-run sign-in (shot 20-p2-claude-a)"
    keys ctrl c; sleep_s 0.5; keys ctrl c; sleep_s 1
    shell_task p2_claude_a_exit 10 "true" || note "STUCK p2 claude: Ctrl-C twice did not return tab A to its shell"
  fi
  keys ctrl '`'; sleep_s 1; main_window p2-b
  shell_task p2_tab_b 10 "cd $work/p2-wt-b" || return 0
  # Task 2: tab B asks in 4 s; the person goes back to tab A first.
  # The job's own start (its job line, the next prompt) is tab B's output too: let it land while tab B is in front, so
  # the only output tab B makes in the background is the ask.
  typeln "(sleep 6; touch $work/p2-asked; printf '\\a\\033]9;Claude needs your permission to use Bash\\a') &"
  sleep_s 1; keys cmd shift "["; sleep_s 0.5; main_window p2-back-a
  shell_task p2_back_in_a 10 "pwd >$work/p2-pwd-a" && [ "$(cat "$work/p2-pwd-a")" = "$work/p2-wt-a" ] ||
    note "STUCK p2: Cmd-Shift-[ did not land in tab A ($(cat "$work/p2-pwd-a" 2>/dev/null))"
  p2_marks before >"$work/p2-marks-before"; p2_mark_keys <"$work/p2-marks-before" >"$work/p2-marks-before.keys"
  local seen="" _i
  grep -q p2-wt-b "$work/p2-marks-before.keys" && note "p2 needs-you: tab B shows a mark before its ask ($(grep -m1 p2-wt-b "$work/p2-marks-before.keys" | cut -f2)): its own output marked it, so the ask's mark is not new"
  for _i in $(seq 1 100); do [ -e "$work/p2-asked" ] && break; sleep_s 0.1; done
  [ -e "$work/p2-asked" ] || { note "STUCK p2: tab B's ask never ran (no shell job in a background tab)"; return 0; }
  t=$(now_ms)
  for _i in $(seq 1 30); do
    p2_marks poll >"$work/p2-marks"
    seen=$(while read -r l; do printf '%s\n' "$l" | p2_mark_keys | grep -qxFf "$work/p2-marks-before.keys" || printf '%s\n' "$l"; done <"$work/p2-marks" | head -1)
    [ -n "$seen" ] && break; sleep_s 0.25
  done
  shot 21-p2-needs-you
  if [ -z "$seen" ]; then
    note "STUCK p2 needs-you: no new unread or needs-you mark within 7.5 s of tab B's ask (marks: $(p2_mark_keys <"$work/p2-marks" | cut -f2 | paste -sd';' -))"; return 0
  fi
  step p2_needs_you_shown "$t"; note "p2 needs-you mark: $seen"
  [ "$(( $(now_ms) - t ))" -gt 2000 ] && note "STUCK p2 needs-you: the mark took over 2 s"
  # The person clicks the mark and expects to be in tab B.
  local key id
  key=$(echo "$seen" | python3 -c 'import json,sys;print(json.load(sys.stdin)["key"])')
  id=$(echo "$seen" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["id"]))')
  t=$(now_ms); ui click "\"$key\":$id" || return 0
  sleep_s 1; main_window p2-clicked; shot 22-p2-clicked
  if shell_task p2_click_lands 10 "pwd >$work/p2-pwd-click" && [ "$(cat "$work/p2-pwd-click")" = "$work/p2-wt-b" ]; then
    step p2_click_to_tab_b "$t"
  else note "STUCK p2 click: the needs-you mark did not land on tab B's terminal ($(cat "$work/p2-pwd-click" 2>/dev/null))"; fi
  memory after-p2 "$pid"
  return 0
}
