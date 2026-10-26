# Chief as a personal assistant: gaps against Instinct and Muse

a676, 2026-10-26. Lawrence: "Chief needs to feel like Instinct/Muse, a much
better personal assistant, with persistence and tenacity."

## What makes them good (sources)

- Instinct ([Doug Levin, first look](https://douglevin.substack.com/p/just-text-it-my-first-look-at-instincts),
  [eesel review](https://www.eesel.ai/blog/instinct-ai-review)): you text it a
  task and it keeps going on its own cloud computer, around the clock. It
  "checks in, keeps track of ongoing tasks" and starts conversations itself:
  a reservation to cancel, a calendar conflict, an email thread to chase.
  You can watch the agents work live. Spending has limits you approve first.
- Muse ([Meta announcement](https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/),
  [Hindsight on its memory](https://hindsight.vectorize.io/blog/2026/09/28/meta-muse-agent-memory)):
  one chat that never ends. It remembers details you said once and acts on
  them unprompted, and it shows what it remembers (you can tell it to
  forget). Long tasks keep running after you close the app, and it comes
  back "when something changes or when it needs approval". It keeps a full
  audit trail of what it did and what it plans to do. It asks first only for
  sensitive steps (sending, buying).

The common pattern: (1) it owns a task until it is done, (2) it reports
without being asked, (3) it remembers a preference after one mention,
(4) it acts and asks only for money, sending or signing in, (5) it puts
what needs the person first.

## Today's Chief (feat-cmux-next, ebb58d7d209)

| Behavior | What exists | Gap |
|---|---|---|
| Follow open tasks | `sleep` wake timers (brain/wakes.rs). Reports always wake the Chief. Reply ledger: every message gets a reply. | Nothing tracks a report that says the work is **not landed**. The Chief only passed it on, and dozens of "unlanded" items piled up in the chat (a98, a121, a603-a619, ...). The prompt had no rule that a handed-off task stays the Chief's. |
| Restart stuck agents by rule | `sub_tick`: a silent subagent gets 2 automatic continues, then a note (control.rs). Errors are auto-resumed with backoff, network waits and usage-limit moves (auto_resume.rs). | Covered for silent and error stops. An agent that ends with **unpushed or red** work was not covered (above). |
| Remember preferences | `optchat/person.md` heads every turn's prompt. The user edits it by hand. | **No tool** writes it. A preference said in chat survived only in the view until it was summarized away (Lawrence's Oct 21 rules had to be written in by hand). |
| Short, acts instead of asking | CHIEF_TURNS: "be brief", "write like a person texting". Subagents get "Decisions: pick the sensible default". | The **Chief's own** prompt had no "decide, do not ask" rule. Only this user's hand-edited profile had it. A new user's Chief asks "Should I...?" |
| Surface what needs the person | person.md (this user only): "Needs you" list at the top. | No general rule. Asks got lost in the middle of long relays. |
| Audit trail / live view | Workspaces per subagent, traces, control status. | Good enough. No change. |

## Fixed (this change)

1. **`remember(text)` tool** (MCP, and `chief remember "text"` for harnesses
   without MCP). It adds one dated line under `## Learned` in
   `optchat/person.md`. A repeat is a noop. It refuses secrets, multiline
   text and long text. A subagent cannot call it. A turn that carries
   another person's text cannot write the owner's profile. The prompt says
   to call it at once on "from now on / always / never".
2. **Landing follow-up by rule, no model call.** When a subagent report says
   its code is not landed (unpushed, unlanded, red, or "not landed" next to
   a sha), the host sends it `[follow-up] ... land it or name the one
   blocker`. The report is filed quietly, with no Chief turn. The next
   report reaches the Chief as usual. Once per subagent
   (`sub_watch::LAND_FOLLOWUPS`).
3. **Chief prompt rules:** follow-through (a task stays yours until it is
   done; act on open reports in the same turn; report done work unasked),
   decide, do not ask ("Default picked: ..."; ask only for money, legal,
   destructive, sign-in; such asks go first, self-contained), and
   preferences (remember at once; never ask what the profile answers).

## Fixed (#25576)

1. **Learned preferences hold at once, in every chat.** The profile is read
   once per host start (the cached prefix), so a line `remember` kept later
   lived only in the chat that called it, until the view summarized it away.
   Now each turn's tail (after the cache marks) names the `## Learned` lines
   the system text lacks, and so does each new subagent's task
   (`assistant::learned_since`, brain/assist.rs, `Spawner::with_learned`).
2. **A promise in prose gets a wake.** A reply that says "I'll check back",
   "I'll let you know" and the like, in a turn that called no `sleep`, has
   no wake pending and no subagent at work, gets a host wake in 15 minutes
   (`assistant::PROMISE_WAKE_SECS`) whose note quotes the promise.
3. **Replies end with the result.** A last post that ends by handing a
   decision back ("Want me to fix it?", "Should I ...?") gets one `[decide]`
   note: do the default and say so, or, when the step needs the person
   (money, legal, destructive, sign-in), leave the question and stop. A
   `[decide]` turn never gets another. The prompt says the same
   ("End every reply with the result or what runs now").
4. Evals: `tests/eval_assistant_followthrough.rs` (deterministic), and the
   model cases `assistant-25576-learned-preference-applied`,
   `assistant-25576-ends-with-result`, `tenacity-25576-blocked-report-surfaced`.
   The model runner mirrors the tail line and the `[decide]` turn, and its
   `remember` stub now writes through the real `remember`.

## Still open

- No "forget" or "show what you remember" view. The file is plain Markdown,
  so the user can edit it now.
