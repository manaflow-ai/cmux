//! A chat's saved metadata (`sessions/<id>/session.json`), the parts it names, and its rules.

use super::*;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionMeta {
    pub schema: String,
    pub id: String,
    pub name: String,
    /// Explicit spoken handle. Older and unnamed sessions derive one from the same stable id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    /// The icon it set for itself or a person gave it (`session_icon.rs`): what every surface
    /// draws for it in place of its harness mark. None draws the harness mark.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<crate::session_icon::SessionIcon>,
    /// Someone gave `name` (at the start, a fork's or a rename), not the daemon's `HARNESS-N`
    /// default (`hub/new_request.rs` `unique_name_among`). False in a log from before it was kept.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub name_given: bool,
    /// The names it had before its renames, oldest first (`hub/former_names.rs`): each still
    /// names it wherever no session has it as its current name, so a message sent to an old
    /// name still arrives. At most `former_names::KEPT`; no other session keeps the same one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub former_names: Vec<String>,
    /// The sessions it took over (`acpmux succeed`), as `HOST/NAME` (or a bare NAME on this
    /// host), each with the former names its predecessor listed. They go out in its heartbeat
    /// row's `formerNames`, so the hub sends a message for a dead predecessor here
    /// (plans/cmux-next/message-delivery-successors.md).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub succeeds: Vec<String>,
    /// The role addresses (`goal:SLUG`, `area:NAME`, `topic:NAME`) it claimed (`acpmux role
    /// claim`): a send to the address reaches it, here and through the hub.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub roles: Vec<crate::mesh::RoleClaim>,
    /// `agent` in a chat stored before the agent-to-harness rename (e857185a58).
    #[serde(alias = "agent")]
    pub harness: String,
    /// `agentArgv` (or `agent_argv`) in a chat stored before that rename.
    #[serde(default, alias = "agentArgv", alias = "agent_argv")]
    pub harness_argv: Vec<String>,
    /// The argv its agent last started with: a config or preset reload since creation can change
    /// it (`harness_argv` is the creation's). None before any start (#23322, review 36).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spawn_argv: Option<Vec<String>>,
    /// `HarnessProfile::launch_digest` of the profile its agent last started from: a profile
    /// reload that changes it respawns the agent at its turn end, on the same conversation
    /// (`hub/profile_respawn.rs`). Kept on disk, so an agent host the next daemon adopts is
    /// judged too. None before any start, or for a start by an older build.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_digest: Option<String>,
    /// Model family of the profile at creation (`claude`, `codex`, ...).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    /// Preset the session was created from (`-p NAME`); its env is re-applied on every respawn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset: Option<String>,
    /// Model requested for a harness whose argv or env carries `${model}`:
    /// applied at spawn, not through set_model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_request: Option<String>,
    /// The effort a new Claude Code chat starts on, given at spawn as `--effort` instead of a
    /// `session/set_config_option` after `initialize` (`hub/lifecycle.rs`). A start before the
    /// harness reported its options reads it (`model_options::spawn_effort`); its reported
    /// effort wins after that.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort_request: Option<String>,
    /// The chat runs a smaller model because its own stayed overloaded
    /// (`hub/auto_resume/capacity_failover.rs`): `from` comes back once a turn on `to` ends well.
    /// Saved with the meta, so a daemon restart still puts it back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capacity_fallback: Option<CapacityFallback>,
    pub cwd: PathBuf,
    /// Folders the chat sees beside `cwd` (ACP `session/new` `additionalDirectories`, its
    /// Sources): every start of its harness gets them (`hub/additional_dirs.rs`). Absolute,
    /// canonical, each once, never `cwd` itself.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub additional_directories: Vec<PathBuf>,
    /// When the chat's agent may stop (`_meta.acpmux.stopCondition`, `hub/stop_condition.rs`):
    /// every start of its Claude Code gets it as a prompt Stop hook, so a would-be stop is
    /// checked against it and the agent goes on until it holds; a Codex (codex-acp) chat gets it
    /// once as Codex's own goal. Kept only for those two; None for none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_condition: Option<String>,
    /// A Codex chat's stop condition was written to Codex as its goal (`stop_condition.rs`):
    /// Codex keeps the goal in its thread, so it is set once.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stop_condition_sent: bool,
    /// Read-only work in a folder the person chose not to trust (`_meta.acpmux.restricted`,
    /// `hub/restricted.rs`): every start of its Claude Code skips the folder's settings and MCP
    /// servers, and it keeps the review policy.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub restricted: bool,
    #[serde(default)]
    pub agent_session_id: Option<String>,
    /// Claude Code can replace its native session id when a chat is forked. Keep ids this
    /// daemon previously recorded for the same chat so transcript reads can follow that history
    /// without scanning another session's store. This is daemon-owned state; it is never inferred
    /// from transcript contents.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub previous_agent_session_ids: Vec<String>,
    /// Every native id this chat had before the current one, whatever its family, oldest first
    /// and bounded (`RETIRED_AGENT_SESSION_IDS`). Not transcript authority: a Codex chat's
    /// earlier native roots, which its older records still name, so a client folding them
    /// (and the tap's `SubagentTree`) never reads an earlier root as one of its subagents.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub retired_agent_session_ids: Vec<String>,
    /// Proven family of the current native id. Older/imported metadata is unknown and cannot
    /// authorize historical Claude reads when that id is retired.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session_family: Option<String>,
    pub status: SessionStatus,
    pub created_at: u64,
    pub updated_at: u64,
    #[serde(default)]
    pub last_seq: u64,
    /// The seq of the newest record `hub/paging.rs` `is_transcript` keeps (the summary's
    /// `transcriptSeq`). 0 from an older daemon's `session.json`: no client compares across
    /// that, since one bump past the value it read is all a client asks of it.
    #[serde(default)]
    pub transcript_seq: u64,
    /// Where the records this machine's own recovery wrote at the end of the journal begin (the
    /// seq before the first of them, `hub/restore_writer.rs` `is_recovery`), while they end it:
    /// any other record appended after them clears it, as does a restore that takes them back.
    /// The summary's `recoveredAfter`, so the owner restores from there a copy that ends at or
    /// before `last_seq` (review of #37284 at 8b5f3063, F2). Saved with the meta, so a machine
    /// that restarts again before its owner reconnects still says it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovered_after: Option<u64>,
    #[serde(default)]
    pub parent_id: Option<String>,
    #[serde(default)]
    pub fork_seq: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_before: Option<ForkBefore>,
    /// A fork's history, read from the chat it came from until written into its own log
    /// (`store/fork_view.rs`). None: its log holds all it shows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_from: Option<HistoryRef>,
    /// The seq through which this log holds a chat's history under that chat's own seqs, so it
    /// skips seqs there: a fork by reference whose history was written into it
    /// (`store/fork_view.rs` `materialize`, `transfer.rs` `export`). Edit and resend's proof of
    /// the log allows those skips (`hub/fork_before.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_kept_through: Option<u64>,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub fork_requests: std::collections::BTreeMap<String, ForkRequest>,
    /// A fork whose agent has not taken the chat's conversation yet ([`ForkStart`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_start: Option<ForkStart>,
    /// Whether this daemon verified the local parent link when the fork was made. Imported
    /// metadata is explicitly unverified, even when an old bundle happened to carry parent ids.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_parent_verified: Option<bool>,
    #[serde(default)]
    pub agent_info: Option<Value>,
    #[serde(default)]
    pub agent_capabilities: Option<Value>,
    /// The agent took prompts mid-turn at its last start (`_meta.steering.supported`). Kept so a
    /// session the daemon adopts after a restart (`hub/hosts.rs`), which never initializes its
    /// agent again, still steers instead of stopping the turn for every prompt sent now.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub steering: bool,
    /// Its agent was launched to write question previews as HTML (`hub/questions.rs`
    /// `PreviewFormat`), kept for the same reason: an adopted agent keeps its launch's format.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub html_previews: bool,
    #[serde(default)]
    pub modes: Option<Value>,
    /// The mode cmux itself last asked the harness for (its start default, the person's pick, a
    /// policy's mode), never one the harness reported on its own: a chat in full access lends its
    /// folder's trust only by this (`hub/trust_wait.rs`), so a harness that claims a mode gets none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode_set_by_cmux: Option<String>,
    #[serde(default)]
    pub config_options: Option<SharedValue>,
    #[serde(default)]
    pub models: Option<Value>,
    #[serde(default)]
    pub permission_policy: Option<String>,
    /// Who set `permission_policy` (`hub/policy_source.rs`); None from an older daemon.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_source: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// Who set `title` (`hub/titles.rs`): `prompt` (its first prompt's line),
    /// `harness` (its own `session_info_update`), `asked` (a generated title
    /// is on its way or came back empty; a later turn asks again, `hub/titles.rs`), `generated`,
    /// `adopted`, `named` (renamed before a title settled: none is generated) or `launched`
    /// (started under a name, not yet prompted).
    /// None: a chat titled before acpmux generated titles; kept as is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title_source: Option<String>,
    /// The first prompt a `prompt` title came from, until a title is asked for.
    #[serde(skip)]
    pub title_prompt: Option<String>,
    /// A title request is running (`hub/titles.rs`); this daemon run only.
    #[serde(skip)]
    pub title_asking: bool,
    /// Title requests that came back with no title in this daemon run (`hub/titles.rs`).
    #[serde(skip)]
    pub title_failures: u8,
    /// The first prompt was too thin to title reliably; permit one refresh after its turn.
    /// Ephemeral so this does not change the stored session format.
    #[serde(skip)]
    pub title_thin: bool,
    #[serde(default)]
    pub last_prompt: Option<String>,
    #[serde(default)]
    pub preview: Option<String>,
    #[serde(default)]
    pub event_count: u64,
    #[serde(default)]
    pub turn_count: u64,
    #[serde(default)]
    pub usage: Option<Value>,
    /// Claude Code's newest /context breakdown (`claude_stdio::context_breakdown`),
    /// sent after each turn; none from any other harness.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_breakdown: Option<Value>,
    /// Cmux-owned additions captured when this chat was created. Older chats have none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmux_context: Option<Vec<crate::context_inventory::ContextPart>>,
    /// A preset override selected at creation; later setting edits affect only new chats.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmux_preset_prompt: Option<String>,
    /// True only after a harness writer accepts the captured first-turn context.
    #[serde(default)]
    pub cmux_context_delivered: bool,
    /// True once cmux's rules on a system-level channel went into the transcript instead,
    /// because a start did not carry them (`context_inventory::append_owed_rules`): once.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cmux_rules_in_transcript: bool,
    /// The seq of the turn whose message carried them (`turn_started`): a fork cut before it
    /// keeps a transcript without them (`context_inventory::fork_keeps_rules`). None for rules
    /// recorded before this was kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmux_rules_seq: Option<u64>,
    /// The account's plan usage limits (`claude_stdio::usage_limits`), newest per window, from
    /// Claude Code's `rate_limit_event`; none from any other harness.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_limits: Option<Value>,
    /// The agent's newest `available_commands_update` (its slash commands), so
    /// opening a chat names them without reading its log back to the start,
    /// where an agent lists them once (perf100). Kept in `session.parts.json`, not
    /// `session.json` (`store/meta_parts.rs`): every other metadata save leaves it unwritten.
    #[serde(default, skip_serializing_if = "meta_parts::skip_commands")]
    pub available_commands: Option<SharedValue>,
    /// Last goal reported by the harness. Codex owns its persistence and continuation.
    #[serde(
        default,
        deserialize_with = "crate::goal::deserialize_option",
        skip_serializing_if = "Option::is_none"
    )]
    pub goal: Option<GoalState>,
    /// Per-session permission rules layered above the policy (see hub/rules.rs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_rules: Option<Value>,
    /// Orchestrator labels: key -> (value, expiry unix ms).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub tags: BTreeMap<String, Tag>,
    /// A turn ended while no client was attached.
    #[serde(default)]
    pub unread: bool,
    /// The log seq the person had seen when they last stopped showing the chat (`hub/seen.rs`):
    /// where "New since you looked" goes when they come back. Set once per hide, never per
    /// record; None until a person has shown and left it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen_seq: Option<u64>,
    /// Turns that ended unseen since the person last showed the chat (the sidebar's count).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub unread_turns: u64,
    /// The person's return to the chat after turns ended unseen, kept while they stay on it: a
    /// client that opens it then draws "New since you looked" at `since`, however its attach and
    /// its list read race. Cleared when the last client showing it stops.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_return: Option<LastReturn>,
    /// The chat's one "While you were away" recap (`hub/away_recap.rs`): a newer recap replaces it,
    /// one that says nothing new is never written, and its dismissal stays across restarts.
    /// None until the first recap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub away_recap: Option<AwayRecap>,
    /// The plan the person last approved (`hub/plan_build.rs` `approved_plan`); None until one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_plan: Option<ApprovedPlan>,
    /// Each person's seen cursor (`hub/seen.rs` `read_through`): the newest log seq they had on
    /// screen while they attended the chat, keyed by person id (`_meta.acpmux.author` id,
    /// [`crate::hub::seen::OWNER_READER`] for the owner). Only `_acpmux/seen` moves it forward; a
    /// restart, update, reconnect, attach or `_acpmux/view` never does. Rows after it by an agent
    /// or another person are the person's unseen rows (the pane's Jump up).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub read_through: BTreeMap<String, u64>,
    /// The Claude conversation acpmux started with a fresh id has not
    /// finished a turn, so Claude may never have stored it (a launcher that
    /// died before the prompt reached Claude stores nothing). A respawn (a
    /// fallback profile, a dead process, a daemon restart) then starts a
    /// fresh conversation instead of `--resume`, which would fail the turn
    /// with "No conversation found with session ID".
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub claude_unstored: bool,
    /// The agent of the unstored conversation (`claude_unstored`) did work in a turn that did
    /// not end Ok: it said something, thought or called a tool (`Hub::unstored_turn_worked`). Only
    /// such a conversation is kept awake (`idle.rs`) and refused by `stop --if-idle`; one whose
    /// turns only ever got agent errors (a 503, an exhausted account) wakes as the same fresh
    /// conversation with its transcript restored either way (cmux#48917).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub claude_unstored_work: bool,
    /// Its creator asked every start of its agent to wait on the harness rather than a wall
    /// clock (`_meta.acpmux.waitStart`, `Session::wait_start`; the Chief's own sessions). Kept on
    /// disk, so a wake after hibernation or a daemon restart waits as its first start did: on
    /// 2026-11-04 a kept Chief session that woke after a restart died at the 90 s deadline again.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub wait_start: bool,
    /// Its creator purges it right after its work (`_meta.acpmux.throwaway`, the Chief
    /// compactor's nodes): its prompts'
    /// `user_message` keeps no long body (`hub/ephemeral.rs`), and a retry or restart never runs
    /// such a prompt again. Kept on disk with the rest of its meta.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub throwaway: bool,
    /// The key its creator sent with its `session/new` (`_meta.acpmux.createKey`,
    /// `hub/create_key.rs`): a create sent again with that key, after a daemon restart closed
    /// the connection before the reply, answers with this session instead of making another.
    /// Kept on disk, so the next daemon finds it too.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub create_key: Option<String>,
    /// What placed it on this machine for another machine's person: `autoCloud`
    /// ([`crate::autocloud_enroll::PLACED_BY_AUTOCLOUD`], `_meta.acpmux.placedBy` on its
    /// `session/new`). Such a chat runs below the owner's own work and gets out of the way when the
    /// owner comes back (`hub/owner_return.rs`). None: started for this machine's own person, or
    /// saved before this existed. Never copied to a fork or a moved-in session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placed_by: Option<String>,
    /// The journal seq the agent's own session ends at, when the journal went past it without
    /// the agent: records its owner kept went back in (`hub/journal_restore.rs`, a session moved
    /// to a fresh machine from an older disk). The agent resumes its own older session, so its
    /// next prompt carries the turns after this seq (`hub/transcript.rs` `missed_turns`), and the
    /// mark goes. Saved with the meta: the agent's file and this mark are on one disk.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_behind_seq: Option<u64>,
    /// When (Unix ms) the idle exit hibernated its agent, 0 when no start woke it since
    /// (`hub/idle.rs`): after a restart, opening it wakes it and its wake draws no row, as
    /// before the restart, and the wake's log says how long it slept.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub hibernated_ms: u64,
    /// Who closed the chat last, why, and whether its work was done (`close_why.rs`): kept on
    /// every close, so a closed row (`close`) says what closed it after its log is compacted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub close: Option<crate::close_why::CloseRecord>,
    /// What the idle census knew of its hosted harness's MCP servers, for the next daemon that
    /// adopts that host (`hub/idle_census.rs`, `StoredLaunch`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_launch: Option<crate::sidecar_census::StoredLaunch>,
    /// The level (`agent_host::HOST_LEVEL`) at which this daemon's build started the chat's live
    /// host, by that host's incarnation (`hub/host_level.rs` `note_start_level`): what the start
    /// asked of the agent (whether it suggests next prompts) is decided there, by the daemon, not
    /// by the host's binary. None: an older daemon started it, or none yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_level: Option<StartLevel>,
    /// Where the chat went when it moved to another daemon (`hub/transfer_out.rs` commit:
    /// `{host?, sessionId, cwd?, branch?, commit?, socket?}`). Set once, never cleared here: a
    /// moved chat takes no prompt and never starts its agent on this daemon again (one writer),
    /// and `resolve` follows it there (`hub/locate.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub moved_to: Option<Value>,
    /// The profile whose Claude store (its CLAUDE_CONFIG_DIR) holds the current Claude
    /// conversation: the one that started or forked it. A respawn on another profile (a failover)
    /// resumes only when that profile's store has the conversation, else starts fresh (E1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_profile: Option<String>,
    /// Outcome of the last turn: {turnId, promptId, status, stopReason?,
    /// errorText?, errorSource?, endedAt}.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_turn: Option<Value>,
    /// An explicit login replaced this account's credentials after this turn. Kept separately
    /// from history so replay and daemon upgrades do not revive an obsolete auth refusal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth_change: Option<AuthChange>,
    /// Classified harness attempts, projected from turn results; old stores default empty.
    #[serde(default)]
    pub harness_failures: crate::session_liveness::HarnessFailures,
    /// Its harness's own command sandbox: first refusal and whether it refuses now
    /// (`hub/harness_sandbox.rs`); old stores default to none.
    #[serde(default, skip_serializing_if = "crate::session_liveness::HarnessSandbox::is_none")]
    pub harness_sandbox: crate::session_liveness::HarnessSandbox,
    /// Created over a remote-origin connection (the WebSocket listener):
    /// its harness never spawns with a preset's args or system prompt.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub remote_origin: bool,
    /// A remote-origin session whose caller asked for the VM boundary
    /// (`hub/vm_boundary.rs`): its Claude Code runs without the platform
    /// sandbox while this machine takes the boundary. A fork or sub-session
    /// keeps it, as it keeps `remote_origin`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub vm_boundary: bool,
    /// Per-session env (`session_env.rs`): allowlisted keys set by the unix
    /// socket on session/new or session/fork, applied over the preset env at
    /// every spawn. Never copied to a fork or a handoff.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub session_env: BTreeMap<String, String>,
    /// The cmux workspace this session works in, as the client named it
    /// (`_meta.acpmux.workspaceId` on session/new or session/fork; a fork
    /// keeps its parent's). It picks the computer use display in
    /// per-workspace display mode (`agent_displays.rs`). Lowercase UUID.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// The harness store of an adopted chat that no profile's store holds
    /// (a subrouter account home, a root the person added; cx-vx54). acpmux
    /// found it in its own chat index, never in a request; every spawn runs
    /// the harness on it (``SessionMeta::apply_chat_store``).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chat_store: Option<PathBuf>,
    /// The adopted conversation's recorded cwd when it was gone here (a chat
    /// moved from another machine) and the session runs in a remapped folder
    /// instead (`hub/adoption.rs` `remapped_cwd`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adopted_cwd: Option<PathBuf>,
    /// Chat store roots the harness's launch env named at its last spawn
    /// (ALL-CHATS-ON-DEVICE C3): absolute, existing folders only.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub harness_roots: Vec<HarnessRoot>,
    /// A Claude Code or Codex conversation this chat shows without running it (`hub/watch.rs`):
    /// cleared when a client takes it over.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watching: Option<Watching>,
    /// Unsent composer text owned by this acpmux session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer_draft: Option<String>,
    /// A person pinned the chat to the top of their list (`_acpmux/pin`), synced to their other
    /// replicas as `pin/<id>` (`hub/synced.rs`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub pinned: bool,
    /// The session took its mode from the person's approval of its preset
    /// (`hub/person.rs` (b)): the approved contents' digest. A spawn from
    /// other contents leaves that mode (`hub/start_gate/preset_bind.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset_mode_approval: Option<String>,
    /// The seqs of this chat's `user_message` records the person bookmarked (the pane's thread
    /// minimap; `hub/bookmarks.rs`). A fork renumbers its copies; a move keeps the log's seqs.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub bookmarks: BTreeSet<u64>,
    /// The tools the chat has (`hub/tools.rs`). Its rows are kept in `session.parts.json`, as
    /// `available_commands` is (`store/meta_parts.rs`).
    #[serde(
        default,
        skip_serializing_if = "meta_parts::skip_tools",
        serialize_with = "meta_parts::tools_without_rows"
    )]
    pub tools: ToolInventory,
    /// Initial branch (session/new or fork; git_state.rs), never updated: it joins the
    /// session to its PR (hq#1920). None outside a repository or on detached HEAD.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    /// Initial git commit and linked-worktree recovery record.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<crate::git_state::WorktreeOrigin>,
    /// The sum of what this session's turns reported (`hub/turn_usage.rs`).
    /// `None` until a harness reports any; a fork starts its own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub totals: Option<TurnUsage>,
    /// The harness's own running cost after the last turn (Claude Code's
    /// `total_cost_usd`), which the next turn's cost is measured from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness_cost_usd: Option<f64>,
    /// What this session's tasks cost so far, model and compute (`hub/turn_cost.rs`): the
    /// `sessionCostUsd` its last priced turn carried. A fork starts its own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_cost_usd: Option<f64>,
    /// The pull requests this session's `gh pr create` calls printed (`hub/pull_requests.rs`),
    /// once each, oldest first. A fork starts with none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pull_requests: Vec<String>,
    /// When each of `pull_requests` was opened (Unix ms), by URL: the review queue's window
    /// counts from it (`hub/review_queue.rs`). One without a time (a meta written before this
    /// field) counts from the session's creation. A fork starts with none.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub pull_request_times: BTreeMap<String, u64>,
    /// The pull requests this session's `gh pr merge` and `gh pr close` calls merged or closed,
    /// by URL (`hub/pull_requests.rs`), whoever's session opened them: none
    /// waits on the person any more (`hub/review_queue.rs`). At most
    /// `pull_requests::MAX_PULL_REQUESTS`, the oldest dropped first. A fork starts with none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub closed_pull_requests: Vec<String>,
    /// The files this session's tool calls read and edited, by repository and path there
    /// (`touched_files.rs`, `hub/touched.rs`): at most `touched_files::MAX_FILES`, the least
    /// recently touched dropped first. A fork starts with none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub touched_files: Vec<crate::touched_files::TouchedFile>,
    /// The session whose agent started this one with its `start_session`
    /// tool (`hub/subsessions.rs`), with its short name and depth. `None`
    /// for a session a person or client started. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subsession: Option<SubsessionLink>,
    /// This session's own sub-session limits, set at runtime by the person
    /// or by an ancestor within its budget; unset fields inherit.
    #[serde(default, skip_serializing_if = "SubsessionLimits::is_empty")]
    pub subsession_limits: SubsessionLimits,
    /// Model races owned by this parent. Shared so per-token metadata copies stay constant-time.
    #[serde(default)]
    pub races: std::sync::Arc<Vec<crate::race_records::Race>>,
    /// The plan builds started from this chat's plan approvals (`hub/plan_build.rs`): set by
    /// acpmux alone, never from a request. Shared as `races` is.
    #[serde(default, skip_serializing_if = "crate::plan_build_records::no_records")]
    pub plan_builds: std::sync::Arc<Vec<crate::plan_build_records::PlanBuildRecord>>,
    /// The session whose agent started this one, recorded once at creation from
    /// the proven caller (`hub/lineage.rs`): `acpmux new` run in an agent's
    /// shell, or its `start_session` tool. `None` for a session a person or
    /// the app started (a root), and for one saved before lineage existed.
    /// Never copied to a fork or a moved-in session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lineage: Option<Lineage>,
    /// Who created it (`hub/created_by.rs`): the person, an agent session or a script,
    /// decided by the daemon at creation from the connection, never from a request
    /// value. `None` for a fork, a moved-in session, and one saved before this existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_by: Option<CreatedBy>,
    /// The log holds a subagent entry with a retry waiting or in flight that no later entry
    /// cleared yet (`hub/subagent_retry.rs`): the next load clears it, as the restart dropped
    /// that retry. Never copied to a fork.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub subagent_retry_open: bool,
    /// The session's own turn cap in ms (`hub/turn_cap.rs`): past it, other agents' messages
    /// wait for the next turn. 0 turns it off; `None` takes the default its settings give
    /// (`turn_cap::default_turn_cap_ms`). Set by the person only; never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_cap_ms: Option<u64>,
    /// The turn the turn cap's notice went into (`hub/turn_cap.rs`), kept so a turn a restart
    /// adopts gets no second one. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_cap_noticed: Option<String>,
    /// The session that first gave this chat work (`hub/inbox.rs`): the sender of the first
    /// message to it before it ran a turn. Its actions wake the idle chat, as its lineage
    /// parent's do. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delegator: Option<String>,
    /// The chat's log is in its cold archive (`hub/cold_archive.rs`, `store/cold.rs`): what the
    /// chat list shows of it without opening the archive. Cleared when the log comes back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cold: Option<ColdPreview>,
    /// The chat's Auto mode (`auto_session/record.rs`): whether it is on, whether this machine
    /// held the chat last, and changes kept aside. Never copied to a fork.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_session: Option<crate::auto_session::record::AutoRecord>,
    /// The subagent of chat `parent_id` this fork holds the conversation of, not the chat's own
    /// (`hub/fork_subagent.rs`). The info view's `forkOf`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_of_subagent: Option<SubagentForkOf>,
    /// The chat's place mode as the place menu set it (`place_mode.rs`): its pin. It is part of
    /// the chat's metadata, so it moves with the chat. None: never picked, which reads as Auto
    /// once this machine's one-time migration pinned every older chat to it (`place_pin.rs`,
    /// `hub/place_migrate.rs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place_mode: Option<crate::place_mode::PlaceMode>,
}

/// A fork of a chat's subagent: the chat, and the subagent as its `_meta.acpmux.subagents`
/// names it (`SessionMeta::fork_of_subagent`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SubagentForkOf {
    pub session_id: String,
    pub subagent_id: String,
    /// Claude's agent id (its sidechain's), or the Codex child's thread id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// A cold-archived chat's preview, kept in `session.json` (`SessionMeta::cold`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ColdPreview {
    /// Unix milliseconds.
    pub archived_at: u64,
    /// The prompts and replies its log held.
    pub messages: u64,
    /// The log's bytes on the disk before, and the archive's.
    pub bytes_before: u64,
    pub bytes_after: u64,
    /// Its last few messages, oldest first, each cut short.
    #[serde(default)]
    pub last: Vec<PreviewMessage>,
}

/// One message of a [`ColdPreview`].
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PreviewMessage {
    /// `user`, `assistant` or `tool`.
    pub role: String,
    pub text: String,
    /// Unix milliseconds.
    pub at: u64,
}

/// The turn whose auth evidence a credential replacement made obsolete. It proves a change,
/// not that the new credential works; the next turn supplies that evidence.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthChange {
    pub at: u64,
    pub turn_id: Option<String>,
    pub ended_at: Option<u64>,
}

/// Where a session sits in the tree of sessions that started each other
/// (`hub/lineage.rs`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Lineage {
    /// The session whose agent started it.
    pub parent: String,
    /// The root of its tree: the first ancestor no agent started.
    pub root: String,
    /// 1 for a child of a root, 2 for a grandchild, and so on.
    pub depth: u32,
    /// The parent's tool call that started it, when acpmux could tell.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

/// `SessionMeta::start_level`: the level a daemon started host `incarnation` at.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StartLevel {
    pub incarnation: String,
    pub level: u32,
}

/// Who created a session (`hub/created_by.rs`), the shape cmux-tui's
/// `workspace.create {created_by}` takes.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
pub struct CreatedBy {
    pub kind: CreatorKind,
    /// The cmux workspace it was created from (lowercase UUID): the agent session's
    /// workspace for an agent, else the one the create named.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    /// The acpmux session whose agent created it; only for `agent`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum CreatorKind {
    /// This host's app, or a connection that proved it is the person.
    Person,
    /// An agent session: its shell's `acpmux new` (a proven caller token) or its
    /// `start_session` tool.
    Agent,
    /// Any other client: a script or the CLI outside a chat.
    Script,
}

/// A sub-session's place in its family (`hub/subsessions.rs`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SubsessionLink {
    /// The parent session's id.
    pub started_by: String,
    /// Its name among its parent's children (unique there), e.g. `tests`.
    pub short_name: String,
    /// 1 for a child of a root session, 2 for a grandchild, and so on.
    pub depth: u32,
    /// The person started it from its parent's suggested task
    /// (`hub/offers.rs`), in a mode they chose: the parent's agent reads
    /// it but does not prompt, stop or close it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub offered: bool,
    /// The worktree its start made for it (`start_session` with `worktree: true`), set by the
    /// daemon then and never by a tag: the only folder a plan build's Keep may remove for it
    /// (`hub/plan_build.rs` `plan_discard`), and only while that folder is still this one.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "MadeWorktree::or_path"
    )]
    pub worktree: Option<MadeWorktree>,
    /// Its change as Compare read it right before a Keep removed its worktree (`added`,
    /// `removed`, `files`, `moreFiles`), set by the daemon: Compare shows it once the folder is
    /// gone, where a read would find nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_build_change: Option<Value>,
}

/// A sub-session's worktree as its start made it: its top folder, that folder's device and inode
/// right after git added it, its creation time, and the branch it was made on. A folder later at
/// `root` is this worktree only while all of them still hold (`hub/plan_build.rs` `still_made`):
/// one made again at the same path after this one went (which may get the same inode) is never
/// removed in its place.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MadeWorktree {
    pub root: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin: Option<crate::cwd_pin::CwdPin>,
    /// Nanoseconds since the epoch at which the folder was created, where the file system says.
    /// A u64 (good to the year 2554): serde's untagged buffer (`or_path`) holds no u128, and a
    /// lineage it cannot read hides the whole chat from every list.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub born: Option<u64>,
    pub branch: String,
    /// The commit it was made from, the base its change is read against (`_acpmux/plan/compare`):
    /// recorded here, where no request writes it, not in the `planBuildBase` tag an agent can.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    /// The random stamp written in its registration folder when it was made
    /// (`subsession_worktree::MADE_STAMP`): a worktree made again at its path has none, even where
    /// it got the same inode and the file system records no creation time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stamp: Option<String>,
}

impl MadeWorktree {
    /// The record, or the top folder alone as a session saved before the record was (its
    /// `worktree` a path): a record with no identity, so nothing is ever removed for it.
    fn or_path<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Self>, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Saved {
            Made(MadeWorktree),
            Path(PathBuf),
        }
        Ok(Option::<Saved>::deserialize(d)?.map(|saved| match saved {
            Saved::Made(made) => made,
            Saved::Path(root) => {
                Self { root, pin: None, born: None, branch: String::new(), base: None, stamp: None }
            }
        }))
    }

    /// The creation time of the folder `held` is open on, in nanoseconds since the epoch.
    pub fn born_of(held: &File) -> Option<u64> {
        let created = held.metadata().ok()?.created().ok()?;
        u64::try_from(created.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos()).ok()
    }
}

/// Limit overrides of one session; `None` inherits its parent's, then the
/// settings, then the defaults (`hub/subsessions.rs`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SubsessionLimits {
    /// Most children this session may have open at once (not closed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_children: Option<u32>,
    /// The deepest level a session under this one may be started at.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_depth: Option<u32>,
    /// Most children running a turn at once (`hub/subsession_runs.rs`); more wait their turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_running: Option<u32>,
}

impl SubsessionLimits {
    pub fn is_empty(&self) -> bool {
        self.max_children.is_none() && self.max_depth.is_none() && self.max_running.is_none()
    }
}

/// What one turn, or a session's turns together, cost (`hub/turn_usage.rs`).
/// A field the harness never reported stays absent rather than 0.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TurnUsage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write_tokens: Option<u64>,
    /// Of `cache_write_tokens`, the hour-long writes (Claude Code's
    /// `cache_creation.ephemeral_1h_input_tokens`), which bill at twice the input price where a
    /// 5-minute write bills at 1.25 times. Absent in older records and for harnesses that do not
    /// say: their writes price at the 5-minute rate.
    #[serde(default, rename = "cacheWrite1hTokens", skip_serializing_if = "Option::is_none")]
    pub cache_write_1h_tokens: Option<u64>,
}

impl TurnUsage {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// Adds `turn` in, field by field; a field neither reported stays absent.
    pub fn add(&mut self, turn: &TurnUsage) {
        fn sum(a: Option<u64>, b: Option<u64>) -> Option<u64> {
            a.zip(b).map(|(a, b)| a.saturating_add(b)).or(a).or(b)
        }
        self.cost_usd = self
            .cost_usd
            .zip(turn.cost_usd)
            .map(|(a, b)| a + b)
            .or(self.cost_usd)
            .or(turn.cost_usd);
        self.input_tokens = sum(self.input_tokens, turn.input_tokens);
        self.output_tokens = sum(self.output_tokens, turn.output_tokens);
        self.cache_read_tokens = sum(self.cache_read_tokens, turn.cache_read_tokens);
        self.cache_write_tokens = sum(self.cache_write_tokens, turn.cache_write_tokens);
        self.cache_write_1h_tokens = sum(self.cache_write_1h_tokens, turn.cache_write_1h_tokens);
    }
}

/// The tools a chat has (`hub/tools.rs`): cmux's own, recorded at each
/// spawn, then what Claude Code's system/init reports.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ToolInventory {
    #[serde(default)]
    pub rows: SharedRows,
    /// The chat can turn MCP servers off (Claude Code, through
    /// `--disallowedTools` at each start); ACP harnesses take their tools at
    /// session start only.
    #[serde(default)]
    pub mutable: bool,
    /// The rows (`mcp:<server>`) this chat turned off. Every start of its
    /// Claude Code disallows their tools; a fork keeps them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub off: Vec<String>,
}

impl ToolInventory {
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty() && !self.mutable && self.off.is_empty()
    }
}

/// One row of a chat's tool list (the summary's `tools`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub struct ToolRow {
    /// `mcp:<server>`, `skill:<name>` or `plugin:<name>`, unique in the chat.
    pub id: String,
    pub name: String,
    /// `mcp`, `skill`, `plugin`, or `cmux` for cmux's own tools.
    pub kind: String,
    /// What gives it: `cmux`, or the harness that reported it (`claude`).
    pub source: String,
    pub enabled: bool,
    /// `_acpmux/set_tools` can turn it on or off in this chat.
    pub can_toggle: bool,
    /// An MCP server's status in the harness's own word (Claude Code's
    /// `connected`, `failed`, `pending`, `needs-auth`, `disabled`), as its
    /// last report gave it; none for a server no harness reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

/// How many earlier native ids a chat keeps (`SessionMeta::retired_agent_session_ids`).
pub const RETIRED_AGENT_SESSION_IDS: usize = 32;

impl SessionMeta {
    pub(crate) fn spoken_handle(&self) -> std::borrow::Cow<'_, str> {
        crate::session_handle::display(self.handle.as_deref(), &self.id)
    }

    /// Whether its harness counts a turn's input apart from the prompt cache, as Anthropic's
    /// usage does, told from what this record knows of how the chat ran (a daemon that has its
    /// config asks the profile's kind first, `Hub::input_excludes_cache`):
    /// - Claude Code over its stream (claude-stdio, whatever its profile is named: the `cmux`
    ///   model router's too), which starts a Claude conversation (`claude_profile`, a Claude
    ///   `agent_session_family`);
    /// - the Claude ACP adapter (`@agentclientprotocol/claude-agent-acp`, formerly
    ///   `claude-code-acp`), which sums `usage.input_tokens` into its ACP `inputTokens`, the
    ///   cache's reads and writes apart, `totalTokens` all four.
    ///
    /// Another ACP harness's input (Codex's, Gemini's) counts the cache's reads in it. A record
    /// that never started its agent says nothing of either, and is read by its names: a harness
    /// named `claude…`, a Claude leaf family (`claude-sr2`), or the `cmux` router's profile
    /// (family `claude`). Plain family `claude` alone is not one, as opencode on a Claude model
    /// is filed under it with its own usage.
    pub fn input_excludes_cache(&self) -> bool {
        if self.claude_profile.is_some()
            || self.agent_session_family.as_deref().is_some_and(|f| f.starts_with("claude"))
        {
            return true;
        }
        let argv = self.spawn_argv.as_ref().unwrap_or(&self.harness_argv);
        if argv
            .iter()
            .any(|arg| arg.contains("claude-agent-acp") || arg.contains("claude-code-acp"))
        {
            return true;
        }
        let harness = self.harness.trim().to_ascii_lowercase();
        let family = self.family.as_deref().unwrap_or("").trim().to_ascii_lowercase();
        harness.starts_with("claude")
            || family.starts_with("claude-")
            || (harness == "cmux" && family == "claude")
    }

    /// Replace the native id, retaining only prior Claude ids as transcript authority.
    /// Explicit provenance prevents a non-Claude id entering history after a profile switch.
    pub fn set_agent_session_id(&mut self, next: Option<String>, family: &str) {
        if let Some(next) = next.as_ref() {
            self.retired_agent_session_ids.retain(|id| id != next);
        }
        if let Some(previous) = self.agent_session_id.clone()
            && next.as_ref() != Some(&previous)
        {
            self.retire_root(previous);
        }
        if let Some(next) = next.as_ref().filter(|_| family == "claude") {
            self.previous_agent_session_ids.retain(|id| id != next);
        }
        let previous_family = self.agent_session_family.as_deref();
        if let Some(previous) = self.agent_session_id.take()
            && previous_family == Some("claude")
            && !(family == "claude" && Some(&previous) == next.as_ref())
            && !self.previous_agent_session_ids.contains(&previous)
        {
            self.previous_agent_session_ids.push(previous);
        }
        self.agent_session_id = next;
        self.agent_session_family = self.agent_session_id.as_ref().map(|_| family.to_owned());
    }

    /// Drop the native id without making it transcript authority: a chat that starts its agent
    /// fresh (a guarded move with no agent file, `transfer_guard.rs`) keeps the old root only in
    /// `retired_agent_session_ids`, since its acpmux history still names it. Never into
    /// `previous_agent_session_ids`, which would let a Claude transcript read follow a file that
    /// did not come with the chat.
    pub fn retire_agent_session_id(&mut self) {
        if let Some(previous) = self.agent_session_id.take() {
            self.retire_root(previous);
        }
        self.agent_session_family = None;
    }

    /// Record an earlier root in `retired_agent_session_ids`: once, newest last, bounded.
    fn retire_root(&mut self, previous: String) {
        if self.retired_agent_session_ids.contains(&previous) {
            return;
        }
        if self.retired_agent_session_ids.len() >= RETIRED_AGENT_SESSION_IDS {
            self.retired_agent_session_ids.remove(0);
        }
        self.retired_agent_session_ids.push(previous);
    }

    /// Claude ids recorded for this chat: current first, then history from newest to oldest.
    /// The caller must separately authorize each ancestor before reading its ids.
    pub fn claude_session_ids(&self) -> impl Iterator<Item = &str> {
        self.agent_session_id
            .iter()
            .filter(|_| self.agent_session_family.as_deref().is_none_or(|f| f == "claude"))
            .chain(self.previous_agent_session_ids.iter().rev())
            .map(String::as_str)
    }

    /// `chat_store` as the harness's store variable (`CLAUDE_CONFIG_DIR` or
    /// `CODEX_HOME`) over `env` (a spawn's, or the env a store is read
    /// with). The harness's default home (`~/.claude`, `~/.codex`) removes
    /// the variable instead: setting `CLAUDE_CONFIG_DIR=~/.claude` moves
    /// Claude's own config file, and with it the person's login. OpenCode's
    /// store `<data>/opencode` is `XDG_DATA_HOME=<data>`.
    pub fn apply_chat_store(&self, env: &mut BTreeMap<String, String>) {
        let Some(dir) = &self.chat_store else { return };
        let (var, default, dir) = match self.family.as_deref() {
            Some("claude") => ("CLAUDE_CONFIG_DIR", ".claude", dir.as_path()),
            Some("codex") => ("CODEX_HOME", ".codex", dir.as_path()),
            Some("opencode") => match dir.parent() {
                Some(data) if dir.file_name().is_some_and(|name| name == "opencode") => {
                    ("XDG_DATA_HOME", ".local/share", data)
                }
                _ => return,
            },
            _ => return,
        };
        let real = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        let default = dirs::home_dir().map(|home| real(&home.join(default)));
        if default.is_some_and(|default| default == real(dir)) {
            env.remove(var);
        } else {
            env.insert(var.to_owned(), dir.to_string_lossy().into_owned());
        }
    }

    /// The Claude store this session's harness reads when it spawns on a
    /// profile with `env`.
    /// A Claude chat whose conversation is not stored (`claude_unstored`) and whose agent did
    /// work in it (`claude_unstored_work`): hibernating or stopping it would lose that work's
    /// context, so `idle.rs` keeps it awake and `stop --if-idle` refuses it (`unstored`).
    pub fn keeps_unstored_awake(&self) -> bool {
        self.claude_unstored && self.claude_unstored_work && self.turn_count > 0
    }

    pub fn claude_store(&self, env: &BTreeMap<String, String>) -> PathBuf {
        let mut env = env.clone();
        self.apply_chat_store(&mut env);
        crate::adopt::HarnessHomes::from_env().with_env(&[&env]).claude
    }
}
