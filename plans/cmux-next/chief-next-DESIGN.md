# Chief next: tenacity, scheduled jobs, Connectome ideas, a durable Cloud Chief

Lawrence, Oct 28: "keep improving chief's tenacity … make sure chief will address everything
user wants chief to address … make sure chief has more capabilities, like running scheduled
jobs … chief will still need to be similar to optchat … consider + add connectome stuff …
completely rewrite cloud chief, such that it uses pi-durable … talk to vercel router too, so we
can support literally every single model."

## 1. Tenacity: what the data says, and the ledgers

Measured on the 3 reachable Chiefs, Oct 20-27 (copies in `~/.cache/chief-evals`, not in this
repo):

| Signal | Lawrence | Austin | Leo |
| --- | ---: | ---: | ---: |
| Subagents whose outcome no Chief post named within 1 h | 108 / 342 (32%) | 15 / 60 (25%) | 5 / 15 (33%) |
| Person messages with no reply within 15 min | 4.4% | 2.5% | 4.8% |
| Messages that could not reach the running turn (steer) | 165 | 18 | 10 |

The host now has two ledgers, both saved in the host state, so a crash or a restart keeps them:

- **Reply ledger** (Oct 21, `brain/reply_ledger.rs`): each person message gets a reply, with retry
  turns and finally a failure note.
- **Outcome ledger** (Oct 28, `brain/outcome_ledger.rs`): each finished subagent is named in a Chief
  post. Otherwise, one `[untold]` retry turn asks for one line per subagent: what changed, its
  link, what is open and what Chief does about it. The host never posts on Chief's behalf.

Still open, in order of size:

1. **The ask ledger.** One person message often holds several asks ("fix X, also Y, and make sure
   Z"). Only the message is tracked, not each ask. Plan: a turn that answers a person message
   records the asks it took (`commit(text, owner)`: a subagent id, "me", or "declined because …").
   An ask with no owner after the turn gets a retry note. This is the mechanism Connectome lacks
   too: its onboarding doc has "no dedicated commitment or task tracker".
2. **Steer cuts** (scratch test, Oct 27): the 3 s deadline lost the running work 4 of 5 times and
   Chief then gave a false reason. Proposed: wait for the next tool boundary, and cut only a tool
   call still running after about 30 s.
3. **Background promises.** "I'll post what it prints when it finishes" was kept 1 of 10 times. Each
   such promise should become a wake or a watch (below), or Chief should not say it.

## 2. Scheduled jobs and watches: Chief gets the tools I use

| My tool (Claude Code) | What it does | Chief today | Plan |
| --- | --- | --- | --- |
| `ScheduleWakeup` | wake once after a delay with a prompt | `sleep(seconds, note, until)`, at most 8 pending, ends the turn | keep it |
| `CronCreate` / `CronList` / `CronDelete` | recurring prompt on a cron schedule | none on the Mac; recurring jobs go to the Cloud Chief (`chief-auto`) | `schedule(cron, prompt)`, `schedules()`, `unschedule(id)` on the Mac host: saved, fired as a turn note, catch up after sleep (one run, not a burst), 7-day default expiry like mine |
| `Monitor` | stream events from a command until a condition | only `fleet_wait` for cmux-ci jobs | `watch(command, until_regex, timeout)`: runs off-turn, wakes Chief once on match, on exit or on timeout, so "tell me when CI is green" is a watch, not a promise |
| `run_in_background` | a long command that wakes me when it exits | subagents only | covered by `watch` with an exit condition |

All of these keep the OptChat contract: a firing is one more message in the one chat (a `note`),
logged and compacted like any other, so the chat stays "forever".

## 3. OptChat/UniiChat against Connectome: what to take

What we already have and should keep, because it is simpler or stronger:

- One append-only log, a binary summary tree of 512-byte nodes written once, a saved view, and
  `zoom`. Connectome's "chronicle" plus "autobiographical" folding (3k-token chunks, fan-in 6, a
  "Pareto" folding solver) is more machinery for the same goal. Our view is byte-bounded and
  cache-stable by design: it grows only at its end between batches, and gets 98.6% prefix cache
  reads in the 3,000-message replay.
- A fresh call per turn, and compaction before the turn.

Ideas worth taking:

1. **First-person, as-known-then summaries.** Connectome's compressor writes "in the agent's own
   voice, using only what it knew at that point". Our compactor already keeps the user's words and
   never overstates progress. Adding "as Chief knew it then" to the compaction prompt is cheap, and
   it fights the memory hole where a later summary rewrites an earlier belief. Test it with
   `replay_compactions` before switching.
2. **A watchdog for "messages arriving but no reply".** Connectome runs it as a cron that restarts
   the agent. Our reply ledger does this inside the host. The missing part is the case where the
   host itself is wedged, and an outside check (the app, or `chief_health`) can catch that.
3. **Head window.** Connectome keeps the opening of the history verbatim. For Chief the
   equivalent is the person's standing rules, which already live in `person.md`. Nothing to add.
4. **Branching** (explore a continuation from a shared past). "Fork to new Chief" already exists.
   Branching inside one chat would break the "one chat" model, so skip it.
5. **MCPL push events** (services push events into the agent). Our watches and wakes cover the
   same need with less protocol.

Not worth taking: an empty system prompt ("identity lives in memory"). Chief's rules must hold
from turn one for a new person, and the reply and outcome ledgers depend on prompt rules.

## 4. Cloud Chief rebuilt on pi-durable, with the Vercel AI Gateway

Today the Cloud Chief is a second implementation: a 6,000-line TypeScript brain in a Cloudflare
Durable Object (`backend/apps/api/src/chief-brain/`), sharing only the memory core (optchat-wasm)
with the Mac Chief. Its prompt has drifted: since Oct 13 the Mac prompt changed 65 times and the
cloud one 9 times, and the cloud has no follow-through, "decide, do not ask", preferences, react
or sleep sections.

pi-durable (Earendil, experimental, about 15k lines of TypeScript) gives:

- durable task steps with checkpoints and `harness.resume()`;
- a tool `replay: "safe"` flag, and a "you were interrupted" note for unsafe tools;
- exactly-once submissions by `requestId`;
- background tasks that outlive a turn, and timers that survive restarts;
- typed documents committed with the transcript;
- SQLite and JSONL storage that can run in a Cloudflare Durable Object with a small adapter;
- remote execution environments, so tools run on a VM while the harness runs elsewhere.

Plan:

1. **One prompt source** for the Mac and Cloud Chiefs, generated from the Rust prompt into a file
   the Cloud Chief bundles, with a CI check that they match. This stops the drift now, before any
   rewrite.
2. **Harness:** pi-durable in the existing Durable Object (SQLite storage adapter), one conversation
   per Chief chat. The OptChat memory stays: the view comes from optchat-wasm, and each turn is a
   fresh pi-durable submission whose input is the view plus the new messages. pi-durable's own
   compaction stays off (the OptChat tree is the memory).
3. **Ledgers as pi-durable documents:** the reply, outcome, ask and schedule ledgers become
   `defineDoc` documents committed with each turn, so a crash never loses one.
4. **Tools:** send, reply, react, spawn, tell, sleep, schedule and watch, each with an honest
   `replay` flag (send has a `requestId` and is safe; spawn is idempotent by key).
5. **Models through the Vercel AI Gateway:** one OpenAI-compatible endpoint
   (`https://ai-gateway.vercel.sh/v1`) with an `AI_GATEWAY_API_KEY` secret. The model is a setting
   per Chief, `provider/model` (for example `anthropic/claude-opus-5-5`, `openai/gpt-6.1-sol`,
   `google/…`). The Claude Code route for Claude logins stays as an option.
6. **Rollout:** the new brain behind a flag, first on Lawrence's Cloud Chief, then on staging. The
   comparison uses the same replay evals as the Mac Chief (dispatch, feedback, rules), plus
   `chief_health` on its traces.

Open questions, decided by default unless someone objects:

- pi-durable is "experimental, the API might still change". Default: pin a version and keep it
  behind an adapter of about 300 lines, so a breaking release is a small change.
- The gateway key is a paid credential. Default: one team key for staging. A production key and
  any spend limits wait for an owner's decision.
