# P2, the 2025 persona (cmuxterm-hq docs/dogfood/personas README): Claude Code in terminal tabs, one per git worktree,
# managed by hand. Sourced by persona-walk.sh after p0 (it uses that script's cua, ui, keys, typeln, shell_task, shot,
# step and note helpers, and its scratch $work, $pid and $cli); not run alone.
#
# p2 walks P2 tasks 1 and 2:
#   1. a scratch repo with two worktrees; Claude Code installed with its official install script when the tab has none
#      (step p2_install_claude; a STUCK line names cmux's "not installed" stand-in when it still answers), then
#      `claude` in a terminal tab (signin=route exports the route's ANTHROPIC_BASE_URL and placeholder key there, as
#      route_on does for the app; signed out, a fresh HOME's claude stops at its first-run sign-in, a STUCK line);
#   2. the background tab asks for the person (the bell and OSC 9 notification Claude Code writes to its terminal
#      when it waits on a permission prompt), the person is in the other tab: the time until the window shows a
#      needs-you mark (an accessibility element naming unread, attention, needs or waiting), then a click on that mark
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
def walk(v):
    if isinstance(v, dict):
        if isinstance(v.get("role"), str):
            yield v
        for c in v.values():
            yield from walk(c)
    elif isinstance(v, list):
        for c in v:
            yield from walk(c)
for e in walk(doc):
    text = " ".join(str(e.get(k) or "") for k in ("label", "name", "title", "description", "value", "help"))
    key = e.get("element_index", e.get("element_token"))
    if key is not None and word.search(text):
        print(json.dumps({"key": "element_index" if "element_index" in e else "element_token", "id": key,
                          "role": e.get("role"), "text": text.strip()[:160]}))
PY
}

p2_claude_check() { # p2_claude_check LABEL: what `claude` answers in the focused tab, into $work/p2-claude-answer
  shell_task "p2_claude_$1" 20 "{ command -v claude || echo no-claude; claude --version; } >$work/p2-claude-answer 2>&1" || return 0
  note "p2 claude $1: $(tr '\n' ' ' <"$work/p2-claude-answer" 2>/dev/null | cut -c1-200)"; }
# cmux's `claude` stand-in, when Claude Code is missing: "cmux: the agent executable was not found" and
# "cmux: Claude Code is not installed. To install it, run: curl -fsSL https://claude.ai/install.sh | bash".
p2_claude_standin() { grep -qiE 'agent executable was not found|Claude Code is not installed' "$work/p2-claude-answer" 2>/dev/null; }
p2_claude_real() { ! p2_claude_standin && grep -qE '[0-9]+\.[0-9]+\.[0-9]+ \(Claude Code\)' "$work/p2-claude-answer" 2>/dev/null; }

p2() {
  local repo="$work/p2-repo" t a b
  git init -q "$repo" && git -C "$repo" -c user.email=p@x -c user.name=persona commit -q --allow-empty -m init &&
    git -C "$repo" worktree add -q "$work/p2-wt-a" -b wt-a && git -C "$repo" worktree add -q "$work/p2-wt-b" -b wt-b ||
    { note "FAIL p2 scratch repo"; return 1; }
  # Task 1: claude in two tabs, one per worktree. The tab's shell is the app's, so what `claude` answers there is what
  # the person has. A runner has no Claude Code, and the `claude` on the tab's PATH may be cmux's stand-in (it prints
  # "Claude Code is not installed"), so the walk first installs it the way a 2025 person did: the official install
  # script, into the scratch HOME, then the PATH line the installer asks for.
  local bin="$work/home/.local/bin" env_line
  env_line="export HOME=$work/home PATH=$bin:\$PATH DISABLE_AUTOUPDATER=1"
  # signin=route: the tab's claude signs through the route, as route_on gives the app (its env reaches the app's
  # daemon, not necessarily a tab's login shell, so the person's export puts it there).
  [ -n "${route_env[*]-}" ] && env_line="$env_line ANTHROPIC_BASE_URL=$base_url ANTHROPIC_API_KEY=sk-ant-placeholder-the-route-signs CLAUDE_CONFIG_DIR=$work/home/.claude"
  main_window p2; keys ctrl '`'; sleep_s 1; main_window p2-a
  shell_task p2_tab_a 10 "cd $work/p2-wt-a && $env_line" || return 0
  p2_claude_check before_install
  p2_claude_standin && note "p2 claude before install: cmux's stand-in answers (Claude Code is not installed on this runner)"
  if ! p2_claude_real; then
    shell_task p2_install_claude 240 "curl -fsSL https://claude.ai/install.sh | bash >$work/p2-claude-install.log 2>&1" ||
      note "STUCK p2 claude: the official install script did not finish in 240 s ($(tail -1 "$work/p2-claude-install.log" 2>/dev/null))"
    p2_claude_check after_install
  fi
  if p2_claude_standin; then
    note "STUCK p2 claude: Claude Code is not installed: the tab's claude is cmux's stand-in ($(grep -m1 -iE 'not installed|not found' "$work/p2-claude-answer"))"
  elif ! p2_claude_real; then
    note "STUCK p2 claude: no claude on the terminal's PATH after the install script ($(head -1 "$work/p2-claude-answer" 2>/dev/null))"
  else
    typeln "claude"; sleep_s 6; shot 20-p2-claude-a
    if [ -n "${route_env[*]-}" ]; then
      note "p2 claude: Claude Code $(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' "$work/p2-claude-answer") started signed through the route (shot 20-p2-claude-a)"
    else
      # Signed out, a fresh HOME's claude has no login: what it shows first is the finding (sign-in, theme, trust).
      note "STUCK p2 claude: a fresh profile's claude stops at its own first-run sign-in (signin=$signin; shot 20-p2-claude-a)"
    fi
    keys ctrl c; sleep_s 0.5; keys ctrl c; sleep_s 1
    shell_task p2_claude_a_exit 10 "true" || note "STUCK p2 claude: Ctrl-C twice did not return tab A to its shell"
  fi
  keys ctrl '`'; sleep_s 1; main_window p2-b
  shell_task p2_tab_b 10 "cd $work/p2-wt-b" || return 0
  # Task 2: tab B asks in 4 s; the person goes back to tab A first.
  typeln "(sleep 4; touch $work/p2-asked; printf '\\a\\033]9;Claude needs your permission to use Bash\\a') &"
  keys cmd shift "["; sleep_s 0.5; main_window p2-back-a
  shell_task p2_back_in_a 10 "pwd >$work/p2-pwd-a" && [ "$(cat "$work/p2-pwd-a")" = "$work/p2-wt-a" ] ||
    note "STUCK p2: Cmd-Shift-[ did not land in tab A ($(cat "$work/p2-pwd-a" 2>/dev/null))"
  p2_marks before >"$work/p2-marks-before"
  local seen="" _i
  for _i in $(seq 1 100); do [ -e "$work/p2-asked" ] && break; sleep_s 0.1; done
  [ -e "$work/p2-asked" ] || { note "STUCK p2: tab B's ask never ran (no shell job in a background tab)"; return 0; }
  t=$(now_ms)
  for _i in $(seq 1 30); do
    p2_marks poll >"$work/p2-marks"
    seen=$(grep -vxFf "$work/p2-marks-before" "$work/p2-marks" | head -1)
    [ -n "$seen" ] && break; sleep_s 0.25
  done
  shot 21-p2-needs-you
  if [ -z "$seen" ]; then
    note "STUCK p2 needs-you: no unread or needs-you mark appeared within 10 s of tab B's ask"; return 0
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
