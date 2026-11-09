# Agent guidance: what cmux tells the agents it runs, and the person's own skills

Leo, 2026-11-05, looking at the Claude Code desktop app's task list, proposed-session cards,
session links and wrap-up box: "presumably specifically in the claude code desktop there are a
few skills/system prompts that let you guys know about them... cmux-next should add a few and we
can think about extending them as well and letting other users define stuff too!"

Code: `cmux-tui/crates/acpmux/src/agent_guidance.rs`, the skill
`cmux-tui/crates/acpmux/skills/cmux-chat/SKILL.md`, the settings
`schemas/settings/source/agent-guidance.json`.

## What agents were told before this

Audit of feat-cmux-next at 186c74f9f54:

| Channel | Who gets it | What |
|---|---|---|
| MCP servers (`agent_tools.rs`) | every local session | `cmux` (`cmux mcp serve`, code mode), `cmux-cua`, `cmux-subsessions` (`start_session` and the rest), `cmux-sessions` (`offer_session`, `suggest_tasks`; only while the app shows offers), `cmux-forum`, `acpmux` (send, ls, last, info), `cmux-agent-memory` (opt-in), Cloud repo tools on Cloud machines |
| MCP `instructions` | every session with `cmux` | `ASKING_RULE` (never ask permission for a harness tool call), `CUA_RULES` with each `cua_*` tool |
| Skills plugin `cmux` (`--plugin-dir`) | Claude Code only | `cmux-browser`, `cmux-cua`, `cmux-customization`, `acpmux`; `cmux-live` comes with the Live Web Reload PR. Only descriptions reach the prompt |
| First-turn context (`context_inventory.rs`) | every harness, Codex included | `CONCURRENT_WORK_RULE` (list what you need, request every independent read in one response from the first step, background long work), replaced by the person's user or project override from the Context viewer |
| Preset system prompt (`--system-prompt-file`) | presets that set one (the Chief) | the preset's text |
| Tool descriptions | every session | each tool says when to use it (`start_session`, `offer_session`, `suggest_tasks`) |

Gaps: nothing told an agent that cmux draws its plan as a checklist, when a side session is right
and when it is not, how to write a session reference cmux turns into a link, or to end a turn with
a recap. Codex got no skills at all. A person could replace the one first-turn rule but could not
add a skill.

## Built-in guidance

One body of guidance, each piece tied to a tool cmux already has and saying when it applies:

| Piece | Applies when | Tool |
|---|---|---|
| Plan list | a task with more than one step | Claude Code `TodoWrite`, Codex `update_plan` (ACP `plan` updates); drawn by the agent pane's PlanList (sibling work: "Agent plans in cmux chats") |
| Side sessions | the person asked for parallel or background work; offer otherwise; never for a step you need now | `start_session` (`worktree: true`), `offer_session`, `suggest_tasks`, `app_agent_open`; Claude Code's own Task tool for a subagent |
| Session links | mentioning another session | `HOST/NAME` or `cmux://agent/<harness>/<id>` in inline code (`sessionRefs.ts` resolves it) |
| Closing recap | a turn that changed files, ran commands or finished multi-step work | none: the reply's last lines |
| Editing cmux live | asked to change how cmux looks or behaves | the `cmux-live` skill (Live Web Reload PR), `cmux-customization` |

Each harness gets it through its own mechanism, not one custom format:

- **Claude Code**: the skill `cmux:cmux-chat` in the existing session plugin (progressive
  disclosure: the description is always listed, the body read when it applies), plus a two-sentence
  pointer in the first-turn context saying when to read it (about 95 tokens; Claude Code's own
  prompt already covers TodoWrite). The Codex text is about 355 tokens.
- **Codex** and every other harness: the full compact guidance in the first-turn context. That is
  the channel Codex itself uses for `AGENTS.md` (a user-role instructions block), so it is the
  native mechanism; acpmux does not write into the person's `CODEX_HOME` or their repo's AGENTS.md.

The guidance is its own context part (`cmux-guidance`), so a person's override of the default
rule keeps it, and the Context viewer lists it with its tokens and channel. It is captured when
the chat is created, like the rest of the first-turn context.

### Where the rules go (2026-11-09)

The default rule (or the person's override of it) and the guidance go on the harness's own
system-level channel when it has one acpmux can set, given at every spawn
(`context_inventory::launch_args`), so they are part of the prefix every chat shares and frame the
person's prompt instead of trailing it:

- **Claude Code**: `--append-system-prompt` (channel `append-system-prompt`), as Claude Desktop
  puts its rules in the system prompt. A profile that passes its own `--append-system-prompt`
  keeps it, and the rules stay in the first message.
- **Codex** (`codex app-server`): `-c developer_instructions=...` (channel
  `developer-instructions`), the developer message Codex puts ahead of a thread's first user
  message. Codex takes one value, so a Codex whose command line, profile or config
  (`config.toml`, the project's) sets `developer_instructions` gets theirs first and cmux's
  after them, read at each spawn from the `CODEX_HOME` that start really uses (presets, routes,
  `${cwd}` expansion applied).
- **Rules longer than 32 KiB** (a long saved override): the first message. Linux refuses one
  launch argument over 128 KiB (`E2BIG`), and the first message has no such bound.
- **Every other harness**, folder instructions, and a chat made before this: the first message
  (`user-context`, `<cmux-…-context>` blocks after the person's words; a client's display parts
  name those words' blocks by index, so nothing goes before them). `cmuxContextDelivered`
  still marks it sent once; the system-level channels are not in the transcript, so a resumed chat
  takes them again as its system prompt, never as a second copy.

The pool's draft captures the same parts, so a pooled agent's command line, and so its key,
matches the chat that takes it.

## The person's layer

- **Skills**: `~/.config/cmux/skills/<name>/SKILL.md` (or `$XDG_CONFIG_HOME/cmux/skills`,
  `CMUX_AGENT_SKILLS_DIR` for tests), the same SKILL.md format Claude Code and Codex use, with
  `name` and `description` frontmatter. Claude Code gets them as a second session plugin,
  `cmux-user` (`cmux-user:<name>`), copied per content hash under `<ACPMUX_HOME>/agent-tools/`
  (regular files only, no symlinks, size and count limits). A symlinked SKILL.md is refused.
  Other harnesses get an index (name,
  description cut to 300 characters, path) in the first-turn context and read the file when it
  applies.
- **Text**: the existing Context viewer override (user or project) stays the way to change the
  always-on rule.
- **Switches**, all on by default, in Settings > Agents > Guidance and Skills, the palette,
  `cmux settings get|set` and MCP `settings_get` (agents may not set them: `userOnly`):
  `agents.guidance.claude`, `agents.guidance.codex`, `agents.guidance.otherAgents`,
  `agents.guidance.userSkills`. They apply to chats created after the change. The Claude switch
  also leaves `cmux-chat` out of the session plugin.

## Later

- A Settings card listing the person's skills with a per-skill switch and "Reveal in Finder".
- Per-project skills (`.cmux/skills` in a repo, after the folder trust check).
- Sharing a skill with a team (a skills repo the team subscribes to).
- Measuring the guidance: a tool eval (`tests/tool-evals/prompt-behavior.mjs`) that checks a plan
  list, a recap and no unrequested `start_session`.
