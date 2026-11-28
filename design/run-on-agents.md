# Run on N agents

One composer prompt sent to 2 to 4 agents at once, each a sub-session in a worktree of its own,
then compared side by side and one kept. Code: `webviews/src/agent-session/acpmux/runOnAgents/`
(the panel), `planBuild/PlanBuildCard.tsx` (the runs card, shared with the plan approval's
compare), acpmux `hub/plan_build.rs` and `server/plan_build.rs` (`_acpmux/plan/fanout`,
`_acpmux/plan/keep {removeOthers}`).

## Ask

Leo, 2026-11-08: "what are the killer features? What are the 10x features? What are the, oh, due
to this, I'm out." Row #8 of the agent-workflow gaps (cmuxterm-hq
`experiments/dealbreakers/gaps-agent-workflow.md`).

## Where it opens

- The composer's + menu, in the composer's own group: **Run on several agents…**, with "Same
  prompt, each in its own worktree; keep the best".
- `/run-on <prompt>`: the prompt stays in the composer and the panel opens for it.
- Send's menu (right-click or hold Send): **Run on several agents… ⌘⌥↩**, under Send, Queue for later
  and Send in side chat, when the draft is text alone.
- ⌘⌥Return with a prompt typed: Command and Option together, the one Return form no app binding takes
  in a chat. Not ⌘⇧Return, which is Ghostty's Toggle Pane Zoom and reserved in every pane.
- Only in a chat that exists on this Mac: not on New Tab, the Quick Composer, Cloud or Sandboxed,
  and not in a chat on another machine (SSH, a Cloud machine), whose runs acpmux refuses.

## The panel

- It opens over the composer and away from the chat, never over the prompt it runs.
- A heading line, one 32 px row per agent (agent, model, effort, remove), then Add agent, Cancel ⎋
  and **Run on N agents ↩**.
- It starts with Claude Opus, Codex and Claude Sonnet when they are installed, otherwise the
  installed agents in turn. It never offers one that is not installed.
- 2 to 4 agents. Remove is off at two and Add is off at four, and acpmux refuses anything else.
- An empty prompt turns Run off, and the heading says to type one first.
- A refusal keeps the panel and the prompt, and the heading gives acpmux's reason in red.
- Rows never change height, so adding or removing an agent moves only the rows under it.

## The runs card

- It is the plan builds card with target `prompt`, headed "Same prompt on N agents". Each column
  shows its agent and model, branch, state, +/− and its first six files.
- Two or three columns sit side by side, and four sit two by two. They stack when narrow. The
  height is fixed per count and width (`planBuildRows`).
- **Keep this one** keeps that run's branch and worktree, closes the others and removes their
  worktrees at once. Worktree care runs with no quiet time and still leaves a worktree that a
  process works in. A worktree goes only once care has archived it (its manifest, and a bundle of
  any work found only there), and its branch stays, so each removed run can be restored. Those
  columns say **Removed**. A worktree that could not go (a process works in it, or care left it)
  is never called removed: its column says **Worktree stayed** in the warning colour with
  acpmux's reason on hover, and the heading says not every worktree was removed.
- Only what the daemon recorded at the start counts: the runs it started as this build and the
  worktree it made for each, kept in each run's lineage, never the tags, which an agent can write.
  A worktree goes only while the folder at its path is still the one made: the same device and
  inode, on the branch it was made on. A folder made again at that path, or a run whose agent moved
  its worktree to another branch, stays and says why.
  The plan approval's own compare keeps its old Keep, where the others are archived and their
  worktrees stay until worktree care's quiet time.

## Gallery

`agent-pane.run-on-agents`: rows (picked), pills and cards, four agents, Add pressed, an empty
prompt, and a refused run. The batch-launch reference is a full modal with a count slider and tool
checkboxes, and these looks are measured against it. Rows won because they scan top to bottom like
the runs card's columns turned on their side, keep a fixed height and fit a narrow pane. Pills wrap
unevenly at three agents, and cards run out of width at four.
`agent-pane.plan-build` `runs` and `runs-kept` show the card.
