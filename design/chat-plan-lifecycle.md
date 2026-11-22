# Chat plan lifecycle: when a task list stays, folds and clears

Leo, 2026-11-21, on a coordinator chat whose hat showed "From before your last message" over a list of
old coordinator tasks: "i dont think we have good enough prompting/calling/expiry maybe? idk what the
lifecycle is for claude code but this may not be that great right now".

## What Claude Code itself does (2.1.330)

- **TodoWrite** replaces the whole list on every call. A call whose items are all `completed` stores an
  empty list: a finished plan clears itself.
- **TaskCreate / TaskUpdate** (the tools `-p` sessions get with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`) keep a
  list on disk. Once every task in it is completed, Claude Code resets the list on its next refresh; the
  next TaskCreate starts a new one.
- **Reminders**: when the tools have not been used for a while, Claude Code adds a system reminder with the
  current list: "consider using ... Also consider cleaning up the task list if it has become stale ...
  ignore if not applicable." Nothing expires by time; the model is asked to keep the list current.

## What cmux did before this change

- acpmux mirrors TaskCreate/TaskUpdate into one ACP `plan` (`claude_stdio/task_plan.rs`), but never
  dropped a finished list: after Claude reset its own, the next create was drawn under the old done steps.
- The chat (`turns.ts earlierTurnPlan`) carried the last list with steps left into every later turn the
  person started, however many turns ago it was written, as "From before your last message". A
  coordinator whose turns are mostly other sessions' messages wrote a list once and never touched it; the
  next time Leo wrote, the hat showed that whole stale list.
- The guidance told agents to write a list, not to clear it.

## The rules now

1. **A finished list clears.** All items done: the list folds into the turn that finished it and never
   carries over (as before). acpmux drops it too, so the next TaskCreate starts a new list, as Claude
   Code's own reset does.
2. **An unfinished list carries over one message only.** The list carries into the turn the person's
   message starts only when the turn right before that message wrote it (the person's turn or another
   session's). One whole turn without touching it and it has expired: it stays folded in the turn that
   wrote it, readable in history, never pinned in the hat. Another session's message never brings it
   back.
3. **The agent's own update ends the carry-over** (as before): a new list, even an empty one, replaces it.
4. **Prompting** (first-turn guidance, `agent_guidance.rs`, and the `cmux-chat` skill): mark each item
   done when done, delete what you drop, and when the person's message changes the work, rewrite or
   clear the list; it is this task's plan, never a standing list of a coordinator's duties.

Not done here: a time-based expiry. Claude Code has none, and a person coming back to "continue" after a
night wants the list; the one-message rule already ends the stale case.

## Where

- `webviews/src/agent-session/acpmux/conversation/turns.ts` `earlierTurnPlan`; tests in
  `conversation/earlierPlan.test.ts`.
- `cmux-tui/crates/acpmux/src/claude_stdio/task_plan.rs`; tests in `task_plan_tests.rs`.
- `cmux-tui/crates/acpmux/src/agent_guidance.rs`, `cmux-tui/crates/acpmux/skills/cmux-chat/SKILL.md`.
