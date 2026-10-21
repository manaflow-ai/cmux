# Chief skills and MCP servers

Status: first slice landed (2026-10-20). Owner: Agents & routing.
The first skill is `chief-auth-escalation` (sign-ins down to one touch).

## Why

The user asked (2026-10-20, Home chat 6039): when a subagent hits a sign-in,
passkey or 2FA, the subagent escalates to its Chief, the Chief drives the
browser on the right to the right page, triggers the passkey step, and the
user only touches the Touch ID sensor. This must be the default for every
Chief, and Chiefs need a general way to carry such workflows: skills, and
MCP servers.

## Decisions (defaults picked; the user can override)

1. **Format: Claude Code skills.** A skill is a folder `<name>/SKILL.md`
   with YAML front matter (`name`, `description`) and Markdown steps. Claude
   Code, Codex and OpenCode harnesses can all read the file, and the same
   folder works as a Claude Code project or user skill without a change.
2. **Two places, one rule.**
   - Shared by every Chief of the user: `~/.cmux/chief/skills/<name>/SKILL.md`
     (the parent of the Chief homes, `$MUX_HOME/../skills`).
   - One Chief's own: `$MUX_HOME/skills/<name>/SKILL.md`
     (`~/.cmux/chief/<chief>/skills`). It wins over a shared skill of the
     same name.
   Code: `Native/OptChat/optchat-chief/src/skills.rs` (`shared_dir`,
   `chief_dir`, `load`).
3. **Shipped skills.** cmux ships skills in the host binary
   (`optchat-chief/skills/<name>/SKILL.md`, `skills::BUILTIN`). At host start
   the host writes them into the shared folder (`install_builtin`). A
   shipped file carries `cmux-managed: true` in its front matter; the host
   rewrites it when an update changes it. A user who edits it and removes
   that line owns the copy, and updates never touch it again. To start from
   a shipped skill without taking it over, copy it under a new name.
4. **How a Chief finds them.** The Chief system prompt (every Chief, from
   `prompt.rs`, not a per-Chief profile) names both folders and says to
   read a skill's SKILL.md before it does what the description names. The
   Chief reads files with its shell. The Claude Code `Skill` tool stays
   denied in Chief turns (`TURN_DENIED_TOOLS`): it would add its listing
   to every turn's uncached prefix, and the same text is one `head` away.
   The prompt keeps no per-install list, so it stays byte-identical across
   turns (cache).
5. **Subagents inherit.** A subagent reads the same two folders (its prompt
   names the escalation tool; its task can name a skill). Subagents keep the
   user's own `~/.claude/skills` too, as before.
6. **Updates.** A new cmux build brings new shipped skills; the next host
   start installs them. No network fetch, no auto-update of user skills.

## Grants (next slice)

`chief_profile::Grant` holds `tools` and `harnesses` today. Add two fields
in the same shape:

- `skills`: the skill names a Chief may use; empty means every skill. The
  host then writes only granted skills into the prompt rule's folders for
  that Chief (a per-Chief view folder, `$MUX_HOME/skills-view/`, made of
  symlinks), so a Chief never sees a skill it was not given.
- `mcp`: the MCP server names a Chief's turns may load, from
  `~/.cmux/chief/mcp.json` (shared, Claude Code `mcpServers` shape) plus
  `$MUX_HOME/mcp.json` (own). The host merges the granted entries into the
  turn session's `.mcp.json` beside `optchat` (session_dir.rs
  `mcp_json_for`), and into the subagent directory's `.mcp.json` when the
  grant says `inherit`. Servers stay out of the prompt text; Claude Code
  lists their tools. Deny-by-default for cmux's own app tools stays as it
  is (cx-68uof).
- The Chief profile UI and `chief chiefs update` take both fields, like
  `tools` today.

## The user adds or edits a skill

- Ask the Chief: "make a skill that ..." The Chief writes
  `~/.cmux/chief/skills/<name>/SKILL.md` (shared) or its own folder, and
  says which.
- Or by hand: make the folder and file; the next turn sees it (no restart:
  the Chief reads the folder when it needs it).
- A skill folder can hold scripts and references beside SKILL.md, as in
  Claude Code; SKILL.md names them by relative path.

## First skill: chief-auth-escalation

Pieces, all landed together:

- **Subagent tool** `escalate_auth {site, url, reason, kind}` with kind
  `password | passkey | 2fa | oauth`, on the subagent's `optchat` MCP
  server, and `chief escalate-auth KIND SITE URL "why"` for harnesses
  without MCP. The host learns the caller's id from its acpmux session
  (`turn_caller.rs` `subagent_of`), else from `ACPMUX_SESSION_NAME`, and
  takes it only from a known subagent of this Chief.
- **Urgent note.** The brain queues `[aN] needs a sign-in (KIND) on SITE ...`
  at the head of the queue and steers it into a running Chief turn at once
  (`Brain::queue_urgent`); it is not a stuck note and never waits behind
  reports.
- **Chief prompt rule** (every Chief): follow the skill, never read or type
  a password or code, press the passkey or security-key button, post one
  line `Needs you: touch the sensor (SITE)`, watch the tab, `tell` the
  subagent when signed in. The old rule "Sign-ins, payments and passwords
  stay with the user" became "payments and typing passwords or codes stay
  with the user".
- **Subagent prompt rule** (every subagent): never wait on a login tab; call
  `escalate_auth` and go on with work that needs no sign-in.
- **Skill** `chief-auth-escalation`: the steps, the fill rules and the
  limits.

### Sites without a passkey-first sign-in

npmjs.com (checked live 2026-10-20) asks for user name and password first
(no `autocomplete=webauthn`), then 2FA, which can be a security key or
Touch ID. So the first step needs the password manager's autofill or the
user's typing; only the 2FA step is one touch. The skill says so and posts
`Needs you: sign in to SITE in the right pane` when no passkey step exists.

### WebAuthn in cmux panes (checked live 2026-10-20)

- cmux NIGHTLY (`com.cmuxterm.app.nightly`, the cmux-next app the user
  runs, build 1.0.0-nightly.3939068198101) has
  `com.apple.developer.web-browser.public-key-credential`. In a WebKit pane
  on webauthn.io, `PublicKeyCredential` exists and
  `isUserVerifyingPlatformAuthenticatorAvailable()` is true.
- A WebAuthn request from a tab behind other tabs fails at once: "The
  document is not focused." After `cmux browser <tab> select` the same
  Authenticate click raised no error and stayed pending (the system sheet's
  wait), but the sheet could not be seen from the agent: no system window
  showed in the on-screen window list and screen capture is not permitted
  to agents. So the skill raises the step with a356's `cmux browser right passkey REF`
  (`browser.page.passkey`, plans/cmux-next/agent-browser-passkey-DESIGN.md):
  `triggered` on a shown tab, else a banner whose click reveals the tab and
  starts WebAuthn. The skill never moves focus itself.
- cmux NEXT (`com.cmuxterm.app.nightly.cmux-next`) is signed without the
  entitlement, and `cmux.next-dev.entitlements` lacks it: its WebKit panes
  cannot offer passkeys. Follow-up: add it to that signing (the
  provisioning profile must carry it).
- CEF (Chromium) panes: not checked yet.
- Follow-up test: an app-level UI test that loads a local WebAuthn page in
  a WebKit pane, selects the tab and asserts the request reaches the
  authenticator (not NotAllowedError), on a fleet Mac with a virtual
  authenticator.

## Tests

- `optchat-chief/tests/auth_escalation.rs`: the tool list, argument checks,
  the launcher form and both prompt rules.
- `optchat-chief/tests/auth_escalation_brain.rs`: an escalation is steered
  into a running Chief turn; unknown subagents are refused; the caller id
  from the session name; shipped-skill install and the Chief-over-shared
  precedence.
