---
name: cmux-terminal-agents
description: "Run many Claude Code or Codex agents as real terminals in cmux, with no fixed limit: start each in its own background workspace in the \"Chief agents\" sidebar group, send prompts, wait for a turn to end (transcript, agent hook, OSC 7501, process exit, screen idle), read the last answer, send continue or a follow-up, close only your own. Use when the Chief or a subagent needs more agents than its spawn tool allows, or wants agents the user can watch and type into."
---

# cmux terminal agents

`scripts/cmux-terminal-agents` drives the real `claude` / `codex` TUI in cmux terminals through the
cmux CLI. Each agent is a workspace the user can open and type into. Nothing focuses a workspace or
raises a window, so the user's focus stays where it is.

```bash
A=skills/cmux-terminal-agents/scripts/cmux-terminal-agents   # or the installed skill's path

$A start fix-login --cwd ~/fun/cmux -- "Read the login bug in issue 123 and propose a fix."
$A start rev-a --harness codex --cwd ~/repo --wait -- "Review the last commit; reply in 5 lines."
$A wait fix-login --timeout 1800          # {"ended": true, "via": "transcript", ...}
$A read fix-login                         # the last answer (transcript for Claude, else screen)
$A send fix-login --wait "Now write the regression test."   # {"submitted": true, "verified": "composer_cleared", ...}
printf 'multi\nline\nprompt\n' | $A send fix-login -   # '-' reads stdin; sent as one paste
$A send fix-login --no-submit "draft"     # paste and check it shows; no Enter
$A key fix-login down --expect 'Yes, I trust'   # any key; returns the screen after it
$A continue fix-login --wait              # sends "continue"; --message "..." for another text
$A list                                   # the agents this tool started, with hook state
skills/cmux-terminal-agents/tests/test-send-verify.sh   # fake-TUI tests (drops early CRs, early input, Enter)
$A close fix-login                        # closes only workspaces this tool started
$A close --all
```

- `start NAME [--harness claude|codex] [--cwd DIR] [--extra ARG]... [--wait] -- PROMPT`: makes a
  workspace named NAME, runs the harness with PROMPT as its first message, and adds the workspace
  to the sidebar group `Chief agents` (created when absent; `CMUX_TERMINAL_AGENTS_GROUP` renames
  it, `--no-group` skips it). Pass harness flags with `--extra`, for example
  `--extra=--model --extra=sonnet`. `--harness claude` runs `sr2 claude` (Claude Code through
  subrouter2); set `CMUX_TERMINAL_AGENTS_CLAUDE=claude` to run the plain `claude` instead.
- `send` never assumes a key landed. It waits for the composer (and fails with
  `stage: blocked_on_prompt` when a prompt or menu is on screen), pastes the text as one
  bracketed paste, reads the screen until the text shows in the composer, then presses Enter as
  a separate mutation and reads again until the submit took: the composer cleared, a new
  "esc to interrupt", a Claude transcript user record, or OSC 7501 `working`. If not, it presses
  Enter once more; if still not, it exits 2 with `{"submitted": false, "stage": ..., "screen": ...}`.
  Success always says `"submitted": true` and which signal proved it in `verified`. When the same
  text already sits unsent in the composer, `send` presses Enter for it instead of pasting twice.
  `--no-submit` pastes and checks it shows, without Enter (composer tests). `--ready-timeout`,
  `--render-timeout`, `--submit-timeout` bound each check.
- `start` checks the TUI came up: with a first prompt it waits for "esc to interrupt", the prompt
  in the transcript, or OSC 7501 `working`; with none, for a ready composer. A trust dialog or
  other menu exits 3 with `stage: blocked_on_prompt` and the prompt text: answer it with `key`,
  `choose` or `steer`, then `send`.
- `key NAME KEY [--repeat N] [--expect REGEX]` presses enter, escape, tab, up, down, backspace,
  ctrl-c, ... or one character, and returns the screen after it with `verified: screen_changed`
  or `no_visible_change`; with `--expect` it exits 2 unless the regex shows.
- `wait` ends on the first signal that fires and says which in `via`:
  1. `transcript`: Claude Code wrote a `turn_duration` record to its session transcript
     (`~/.claude/projects/*/<session>.jsonl`). Local file read, about 0.2 s after the turn ends.
  2. `hook`: the cmux agent hook state of the terminal went from `running` to idle, done or
     blocked (`cmux agent list`). Needs `cmux agent hook install`.
  3. `osc7501`: the agent's OSC 7501 program-status record (`cmux terminal <t> status`,
     `app=claude-code` or `app=codex`) left `working`.
  4. `exit`: the agent process exited.
  5. `screen`: the screen did not change for `--idle-seconds` (default 20; 0 turns it off) and
     shows no "esc to interrupt". This is the last resort and can be slow or wrong for an agent
     that thinks silently for a long time.
  A hook or OSC 7501 signal ends the wait only after that same signal reported this turn running
  (Codex's hook says idle right after submit, before working).
  A `--timeout` that passes returns `{"ended": false, "via": "timeout"}`; the agent keeps running,
  so wait again instead of sending the prompt again.
- `read` prints the last assistant text. For Claude it comes from the transcript (complete, even
  when the answer scrolled off the screen). For Codex it is the screen text after the last prompt.
- State lives in `~/.cmux/terminal-agents/agents/<name>.json` (`CMUX_TERMINAL_AGENTS_DIR`). `close`
  closes only workspaces recorded there.

## Rules

- After every single action, check the screen; never assume a key landed. The tool does this for
  `start`, `send`, `continue`, `steer`, `choose` and `key`, and each returns the screen after the
  action and the state it verified. Trust that, not the exit of a raw `cmux terminal write`.
  Never type into an agent with a bare `cmux terminal write ... \r`: a CR that arrives while the
  TUI is still processing a paste, or input sent before it is ready, is dropped silently.
- A non-zero exit means the action did not take: read `stage` and `screen` and act on them
  (answer a prompt, wait for the TUI); do not resend blindly.

- There is no agent cap in this tool. The real limit is the Mac: watch `uptime` load and free
  memory before you start many agents, and start fewer when the cmux CLI starts timing out.
- The cmux CLI can fail for a moment under heavy load ("does not speak cmux.protocol/2", "Broken
  pipe", "did not finish within"). The tool retries these with the printed idempotency key, so a
  retried write is not sent twice.
- Never close, rename, or type into a workspace you did not start. Never focus one.
- Do not poll `read` in a loop. Use `wait`, then `read` once.
- Give each agent a clear task and an end condition. Tell it what to put in its final answer,
  because `read` returns only that.

## Prompts: find and answer them yourself
- `cmux-terminal-agents prompts [--terminal term_…]` lists agents stuck on a permission prompt or menu, with the prompt text.
- `cmux-terminal-agents choose <name|term_…> N` picks option N when that choice is safe, then checks the menu went away (`verified: prompt_gone` or `menu_changed`); it exits 2 when no menu is on screen or the same menu stays. When the menu ignores the digit (Codex's menus), it moves the selection with arrow keys, checking each step on screen, then presses Enter (`method: arrows`).
- `cmux-terminal-agents steer <name|term_…> "instructions"` presses Esc (dismisses the prompt, or with `--esc 2` interrupts the turn), checks what the Esc did (`esc.verified`: `prompt_gone`, `turn_interrupted`, `still_busy`, `nothing_to_dismiss`), and then does a verified `send` of the instructions. Use this to redirect an agent instead of approving something risky.
- Check `prompts` whenever an agent goes quiet. Ask the user only for money, legal, destructive or credential-minting steps.

## Native subagents first
For a Chief's own subagents (`a<N>`), use the native tools instead of this skill:
`tell` (never fails for a queued or starting one; it is delivered after its task) and
`control` (status, interrupt, answer, pause, resume, cancel, restart, priority, cap).
Prompts, stuck runs and reports reach the Chief as messages, so nothing polls a screen.
Use this skill only for agents in plain terminals.
