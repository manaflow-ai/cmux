//! The compactor's model through acpmux (as mux/host/src/compactor.ts does):
//! the team subrouter serves Claude Code clients and answers raw Messages
//! API calls with 429, so on the subrouter each node is built by the normal
//! harness (claude-sr) in its own acpmux session, never by a request that
//! pretends to be Claude Code.
//!
//! One node, one session: `deny-all`, every tool denied, and the
//! compactor's own acpmux preset, which the session REQUIRES (acpmux refuses
//! to start it without the preset, so it never falls back to the user's
//! `~/.claude`). The preset points `CLAUDE_CONFIG_DIR` at the compactor's
//! own configuration (`optchat/compactor-claude`, separate from the turn
//! agent's), turns off auto-memory, CLAUDE.md files, bundled skills and
//! Claude Code's own refusal fallback. The session's cwd is a slot
//! directory under the system temporary directory, outside any directory
//! with instruction files. The request maps onto the session's prompts.
//! On a Claude harness whose acpmux takes a preset `systemPrompt`, the
//! cached layout: each slot has its own preset, whose system prompt the
//! node sets to the system text plus the context up to the first cache mark
//! (acpmux writes it into its own preset directory and checks its sha256
//! when the session starts), and the first prompt is the rest of the
//! context with one `cache_control` marker at the last mark, then the step
//! (`cached_prompt`). Otherwise the old layout: the system text, the
//! context pieces and the step as one prompt, which a harness with
//! automatic prefix caching (codex) reads back from its cache as long as
//! the prefix is byte-identical; its nodes share one working directory. Each size loop retry is the next prompt in the same session, the
//! reply text the line. `end` (after the node is built or failed) kills the session with
//! purge, deletes its Claude Code transcript and logs its seconds and token
//! use. At most JOBS sessions live at once across the main and fallback
//! compactors (one `Slots` gate).

use std::collections::{BTreeMap, HashMap};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{RecvTimeoutError, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::acp::AcpmuxEvent;
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, ModelError, NodeId, PROBE_NODE, Reply,
};
use serde_json::{Value, json};

use crate::acpmux::{AgentPort, Family, Preset, SessionSpec, TurnSignal};
use crate::fold::{TurnFold, Usage, answer_usage};
use crate::paths::{Paths, home_id};

/// The permission policy of every compactor session: a node needs no tool.
pub const POLICY: &str = "deny-all";

/// Longest one compactor prompt may take, the session's start included.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(300);

/// Days Claude Code keeps a compactor transcript that `end` could not
/// delete (a crash); its minimum.
pub const TRANSCRIPT_DAYS: u64 = 1;

/// Claude Code's built-in tools, denied in each compactor slot's project
/// settings so the harness does not offer them (section 4.2: no tools;
/// checked live: a tool denied in project settings leaves the model's list).
/// The interactive ones matter most: acpmux keeps questions and plan
/// approval for a human under every policy, so one call would hang the
/// node (and, under rule 3, every turn) until `CALL_TIMEOUT`. The
/// `deny-all` policy refuses any call that still happens, and the start-up
/// probe reports any tool or MCP server the session still offers.
pub const DENIED_TOOLS: [&str; 48] = [
    "Agent",
    "AskUserQuestion",
    "Bash",
    "BashOutput",
    "CronCreate",
    "CronDelete",
    "CronList",
    "DesignSync",
    "Edit",
    "EnterPlanMode",
    "EnterWorktree",
    "ExitPlanMode",
    "ExitWorktree",
    "Glob",
    "Grep",
    "KillShell",
    "LS",
    "LSP",
    "ListAgents",
    "ListMcpResourcesTool",
    "Monitor",
    "MultiEdit",
    "NotebookEdit",
    "NotebookRead",
    "PushNotification",
    "Read",
    "ReadMcpResourceTool",
    "RemoteTrigger",
    "ReportFindings",
    "ScheduleWakeup",
    "SendMessage",
    "Skill",
    "SlashCommand",
    "Task",
    "TaskCreate",
    "TaskGet",
    "TaskList",
    "TaskOutput",
    "TaskStop",
    "TaskUpdate",
    "TeamCreate",
    "TeamDelete",
    "TodoWrite",
    "ToolSearch",
    "WebFetch",
    "WebSearch",
    "Workflow",
    "Write",
];

/// How compactor sessions start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompactorSpec {
    /// Session names are `<name>-<node>` (`<name>-probe` for the probe).
    pub name: String,
    /// Where the slot working directories live (`<work>/slot-<k>`): outside
    /// the home, so no CLAUDE.md of a parent directory loads.
    pub work: PathBuf,
    /// Claude Code configuration directories a node's transcript may land
    /// in (under `projects/`), each cleaned when the node ends: the
    /// compactor's own `CLAUDE_CONFIG_DIR`, and the user's Claude home,
    /// because `sr claude proxy` (claude-sr) resets `CLAUDE_CONFIG_DIR` to it.
    pub transcript_dirs: Vec<PathBuf>,
    /// The base name of the acpmux presets compactor sessions require: slot
    /// `k` uses `<preset>-slot-<k>` (`slot_preset`).
    pub preset: String,
    pub harness: String,
    /// The harness's family as acpmux reports it (`acpmux::harness_family`).
    pub family: Family,
    /// Codex: the slots' own `CODEX_HOME`s live under it (`<dir>/slot-<k>`,
    /// `codex_slot_home`), emptied but for their configuration around
    /// every node.
    pub codex_home: PathBuf,
    pub model: Option<String>,
    /// acpmux's `effort`; None (the harness default) until verified live.
    pub effort: Option<String>,
    /// Longest one prompt may take.
    pub timeout: Duration,
    /// This Chief's home id: the `cmux.chief` tag on every compactor session.
    pub chief: String,
}

/// The session slots of the compactor (the core's JOBS), shared by the main
/// and the fallback compactor. Each slot has its own working directory, so a
/// node's Claude Code project directory holds only that node's transcript.
pub struct Slots {
    free: Mutex<Vec<bool>>,
    freed: Condvar,
}

impl Slots {
    pub fn new(jobs: usize) -> Arc<Slots> {
        Arc::new(Slots {
            free: Mutex::new(vec![true; jobs.max(1)]),
            freed: Condvar::new(),
        })
    }

    fn take(&self) -> usize {
        let mut free = self.free.lock().expect("slots");
        loop {
            if let Some(k) = free.iter().position(|f| *f) {
                free[k] = false;
                return k;
            }
            free = self.freed.wait(free).expect("slots");
        }
    }

    fn give(&self, k: usize) {
        if let Some(slot) = self.free.lock().expect("slots").get_mut(k) {
            *slot = true;
        }
        self.freed.notify_one();
    }
}

/// A node's open session.
struct Live {
    id: String,
    /// The last event seq already read.
    seq: u64,
    slot: usize,
    cwd: PathBuf,
    /// The slot's preset, and whether this node set its system prompt.
    preset: String,
    prompted: bool,
    opened: Instant,
    prompts: u32,
    /// Token use the harness reported, summed over the node's prompts.
    usage: Option<Usage>,
    cost: Option<f64>,
    /// The last prompt's failure (None: it built the line), for the trace.
    error: Option<String>,
    /// The node's context as the trace records it (size, hash, pieces).
    context: Value,
}

pub type Log = Arc<dyn Fn(&str) + Send + Sync>;

pub struct AcpmuxCompactor {
    port: Arc<dyn AgentPort>,
    spec: CompactorSpec,
    slots: Arc<Slots>,
    live: Mutex<HashMap<NodeId, Live>>,
    prompts: AtomicU64,
    /// Makes prompt ids unique across host starts (acpmux runs an id once).
    stamp: u64,
    /// Claude Code refused the node's cache marker (it placed a fourth
    /// breakpoint of its own): later nodes go without it.
    marker_refused: AtomicBool,
    log: Option<Log>,
    trace: crate::trace::Trace,
}

impl AcpmuxCompactor {
    pub fn new(
        port: Arc<dyn AgentPort>,
        spec: CompactorSpec,
        slots: Arc<Slots>,
    ) -> AcpmuxCompactor {
        AcpmuxCompactor {
            port,
            spec,
            slots,
            live: Mutex::new(HashMap::new()),
            prompts: AtomicU64::new(0),
            stamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_millis() as u64),
            marker_refused: AtomicBool::new(false),
            log: None,
            trace: crate::trace::Trace::off(),
        }
    }

    /// Traces every node: seconds, prompts, token use, cost, outcome.
    pub fn with_trace(mut self, trace: crate::trace::Trace) -> AcpmuxCompactor {
        self.trace = trace;
        self
    }

    /// Logs one line per node: its seconds, prompts and token use.
    pub fn with_log(mut self, log: Log) -> AcpmuxCompactor {
        self.log = Some(log);
        self
    }

    fn say(&self, line: &str) {
        if let Some(log) = &self.log {
            log(line);
        }
    }

    fn session_name(&self, node: NodeId) -> String {
        if node == PROBE_NODE {
            format!("{}-probe", self.spec.name)
        } else {
            format!("{}-{}", self.spec.name, node.name())
        }
    }

    /// A Claude Code harness: the cached layout's flags and system prompt
    /// apply, and each slot needs its own directory (Claude Code keeps a
    /// transcript per project directory, deleted per node).
    fn claude(&self) -> bool {
        self.spec.family == Family::Claude
    }

    /// Codex: empties the slot's `CODEX_HOME` but for its configuration
    /// (the node's transcript, thread database and logs go).
    fn wipe_codex(&self, slot: usize) {
        if self.spec.family != Family::Codex {
            return;
        }
        let dir = codex_slot_home(&self.spec.codex_home, slot);
        if let Err(e) = wipe_codex_home(&dir) {
            self.say(&format!(
                "emptying the compactor's CODEX_HOME {}: {e}",
                dir.display()
            ));
        }
    }

    /// The slot's working directory, created, by its real path (Claude
    /// Code names the project directory after the real path). Another
    /// harness shares one directory across slots: codex names the cwd in
    /// its environment context, ahead of the prompt, so one cwd keeps the
    /// request prefix identical from node to node.
    fn slot_dir(&self, slot: usize) -> io::Result<PathBuf> {
        private_dir(&self.spec.work)?;
        let dir = if self.claude() {
            self.spec.work.join(format!("slot-{slot}"))
        } else {
            self.spec.work.join("shared")
        };
        private_dir(&dir)?;
        // Project settings: the only settings claude-sr is sure to read
        // (sr resets CLAUDE_CONFIG_DIR, so the preset's user settings are
        // not), and the ones that take denied tools off the model's list.
        std::fs::create_dir_all(dir.join(".claude"))?;
        write_settings(&dir.join(".claude").join("settings.json"))?;
        std::fs::canonicalize(&dir)
    }

    /// Opens the node's session (a slot first, so at most JOBS live), with
    /// `system` as its slot preset's system prompt in the cached layout.
    fn open(&self, node: NodeId, system: Option<&str>) -> Result<String, ModelError> {
        // Claude only through acpmux's own Claude Code adapter
        // (harness_gate), checked before a slot is taken.
        let admitted =
            crate::harness_gate::admit_live(&*self.port, &self.spec.harness).map_err(|reason| {
                self.say(&format!("compactor node {}: {reason}", node.name()));
                crate::harness_gate::trace_refusal(
                    &self.trace,
                    "compactor",
                    &self.spec.harness,
                    &reason,
                );
                ModelError::new(crate::harness_gate::refusal(&reason))
            })?;
        let slot = self.slots.take();
        let cwd = match self.slot_dir(slot) {
            Ok(cwd) => cwd,
            Err(e) => {
                self.slots.give(slot);
                return Err(ModelError::new(format!(
                    "creating the compactor's working directory: {e}"
                )));
            }
        };
        let preset = slot_preset(&self.spec.preset, slot);
        // The slot is this node's alone, so is its preset: no other node
        // changes the prompt before this session starts with it.
        if let Some(text) = system
            && let Err(e) = self.port.set_system_prompt(&preset, text)
        {
            self.slots.give(slot);
            return Err(ModelError::new(format!(
                "setting the compactor's system prompt: {e}"
            )));
        }
        // A transcript left by a crash in this slot.
        self.delete_transcript(&cwd);
        self.wipe_codex(slot);
        let name = self.session_name(node);
        // Left by a host that stopped while the node was being built.
        if let Ok(Some(old)) = self.port.find(&name) {
            let _ = self.port.end_session(&old);
        }
        let spec = SessionSpec {
            name,
            cwd: cwd.clone(),
            harness: admitted.profile.clone(),
            policy: POLICY.to_owned(),
            model: self.spec.model.clone(),
            effort: self.spec.effort.clone(),
            preset: Some(preset.clone()),
            tags: crate::acpmux::chief_tags(&self.spec.chief, "compactor"),
        };
        let opened = self.port.new_session(&spec).and_then(|id| {
            // The session's own harness is what answers (a name that is
            // also a family resolves through acpmux's preference list).
            match crate::harness_gate::session_harness(&*self.port, &id, &admitted) {
                Ok(_) => Ok(id),
                Err(reason) => {
                    let _ = self.port.end_session(&id);
                    crate::harness_gate::trace_refusal(
                        &self.trace,
                        "compactor",
                        &self.spec.harness,
                        &reason,
                    );
                    Err(crate::harness_gate::refusal(&reason))
                }
            }
        });
        match opened {
            Ok(id) => {
                self.live.lock().expect("live").insert(
                    node,
                    Live {
                        id: id.clone(),
                        seq: 0,
                        slot,
                        cwd,
                        preset,
                        prompted: system.is_some(),
                        opened: Instant::now(),
                        prompts: 0,
                        usage: None,
                        cost: None,
                        error: None,
                        context: Value::Null,
                    },
                );
                Ok(id)
            }
            Err(e) => {
                self.slots.give(slot);
                Err(ModelError::new(format!(
                    "starting a compactor session: {e}"
                )))
            }
        }
    }

    fn delete_transcript(&self, cwd: &Path) {
        for root in &self.spec.transcript_dirs {
            let dir = root.join("projects").join(project_dir_name(cwd));
            if dir.exists()
                && let Err(e) = std::fs::remove_dir_all(&dir)
            {
                self.say(&format!(
                    "deleting the compactor transcript {}: {e}",
                    dir.display()
                ));
            }
        }
    }

    /// One prompt in the node's session; its reply text.
    fn prompt(&self, node: NodeId, session: &str, blocks: Vec<Value>) -> Result<Reply, ModelError> {
        let n = self.prompts.fetch_add(1, Ordering::SeqCst);
        let prompt_id = format!("optchat-compact:{}:{}:{n}", self.stamp, node.name());
        let (tx, rx) = channel();
        self.port
            .start_prompt(session, blocks, &prompt_id, tx)
            .map_err(|e| ModelError::new(format!("prompting the compactor session: {e}")))?;
        let deadline = Instant::now() + self.spec.timeout;
        let answer = loop {
            match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(TurnSignal::Changed) => {}
                Ok(TurnSignal::Done(answer)) => break answer,
                Ok(TurnSignal::Lost) | Err(RecvTimeoutError::Disconnected) => {
                    return Err(ModelError::new(
                        "the acpmux connection was lost during a compactor call",
                    ));
                }
                Err(RecvTimeoutError::Timeout) => {
                    let _ = self.port.cancel(session);
                    return Err(ModelError::new(format!(
                        "the compactor session did not answer within {} s",
                        self.spec.timeout.as_secs()
                    )));
                }
            }
        };
        // acpmux answers a refused Claude turn with a JSON-RPC error that
        // carries Claude Code's text (claude_stdio/inbound.rs), never with
        // `stopReason: "refusal"`; both are refusals.
        let answer = answer.map_err(|e| {
            if is_refusal_error(&e) {
                ModelError::refusal(format!("refused: {e}"))
            } else {
                ModelError::new(format!("compactor session: {e}"))
            }
        })?;
        self.count(node, &answer);
        match answer.get("stopReason").and_then(Value::as_str) {
            Some("refusal") => {
                return Err(ModelError::refusal(format!("refused: {answer}")));
            }
            Some("max_tokens") => return Err(ModelError::new("reply hit max_tokens")),
            Some("end_turn") | None => {}
            Some(other) => {
                return Err(ModelError::new(format!(
                    "the compactor turn stopped early ({other})"
                )));
            }
        }
        let after = self
            .live
            .lock()
            .expect("live")
            .get(&node)
            .map_or(0, |l| l.seq);
        let events = self
            .port
            .events(session, after)
            .map_err(|e| ModelError::new(format!("reading the compactor reply: {e}")))?;
        if node == PROBE_NODE {
            check_isolation(&events).map_err(ModelError::new)?;
        }
        let mut fold = TurnFold::after(after);
        for event in &events {
            fold.apply(event);
        }
        fold.finish(None);
        if let Some(l) = self.live.lock().expect("live").get_mut(&node) {
            l.seq = fold.seq();
        }
        if let Some(error) = fold.ended().and_then(|e| e.error.clone()) {
            return Err(ModelError::new(format!("compactor turn: {error}")));
        }
        Ok(Reply::text(strip_preamble(
            fold.final_text().unwrap_or_default(),
        )))
    }

    /// Adds a prompt's reported token use and cost to its node.
    fn count(&self, node: NodeId, answer: &Value) {
        let mut live = self.live.lock().expect("live");
        let Some(l) = live.get_mut(&node) else { return };
        l.prompts += 1;
        if let Some((u, _)) = answer_usage(answer) {
            let sum = l.usage.get_or_insert_with(Usage::default);
            sum.input += u.input;
            sum.cache_read += u.cache_read;
            sum.cache_write += u.cache_write;
            sum.output += u.output;
        }
        if let Some(cost) = answer
            .pointer("/_meta/claude/cost_usd")
            .and_then(Value::as_f64)
        {
            *l.cost.get_or_insert(0.0) += cost;
        }
    }
}

impl AcpmuxCompactor {
    /// A node's first prompt in the cached layout (when the preset carries
    /// its args): the system prompt file, one marker, and one retry without
    /// the marker when Claude Code's own breakpoints leave no room for it.
    fn first_cached(&self, request: &CompactRequest) -> Result<Reply, ModelError> {
        let node = request.node;
        let marker = !self.marker_refused.load(Ordering::SeqCst);
        let layout = cached_prompt(request, marker);
        let session = self.open(node, Some(&layout.system))?;
        let has_marker = layout
            .blocks
            .iter()
            .any(|b| b.get("cache_control").is_some());
        match self.prompt(node, &session, layout.blocks) {
            Err(e) if has_marker && is_marker_limit_error(&e.message) => {
                self.marker_refused.store(true, Ordering::SeqCst);
                self.say(&format!(
                    "compactor node {}: Claude Code refused the cache_control marker ({}); retrying without it, and later nodes go without it",
                    node.name(),
                    e.message
                ));
                // A fresh session: the refused prompt may sit in the old one's history.
                self.end(request);
                let layout = cached_prompt(request, false);
                let session = self.open(node, Some(&layout.system))?;
                self.prompt(node, &session, layout.blocks)
            }
            other => other,
        }
    }
}

impl AcpmuxCompactor {
    fn call_inner(
        &self,
        request: &CompactRequest,
        followups: &[Followup],
    ) -> Result<Reply, ModelError> {
        let node = request.node;
        let (session, blocks) = match followups.last() {
            None => {
                // A fresh conversation: whatever an earlier try left is gone.
                self.end(request);
                if self.claude() && self.port.system_prompt(&slot_preset(&self.spec.preset, 0)) {
                    return self.first_cached(request);
                }
                (self.open(node, None)?, request_blocks(request))
            }
            Some(last) => {
                let session = self
                    .live
                    .lock()
                    .expect("live")
                    .get(&node)
                    .map(|l| l.id.clone())
                    .ok_or_else(|| ModelError::new("the node's compactor session is gone"))?;
                (session, vec![text_block(&last.retry)])
            }
        };
        self.prompt(node, &session, blocks)
    }
}

impl CompactModel for AcpmuxCompactor {
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        let result = self.call_inner(request, followups);
        if let Some(l) = self.live.lock().expect("live").get_mut(&request.node) {
            l.error = result.as_ref().err().map(|e| e.message.clone());
            if l.context.is_null() {
                l.context = json!({
                    "bytes": request.context.len(),
                    "hash": crate::trace::hash(&request.context),
                    "pieces": crate::trace::pieces(&request.context),
                    "system_hash": crate::trace::hash(&request.system),
                });
            }
        }
        result
    }

    fn end(&self, request: &CompactRequest) {
        let Some(live) = self.live.lock().expect("live").remove(&request.node) else {
            return;
        };
        self.trace.emit(
            "node",
            json!({
                "node": request.node.name(),
                "harness": self.spec.harness,
                "model": self.spec.model,
                "ms": live.opened.elapsed().as_millis() as u64,
                "prompts": live.prompts,
                "usage": live.usage.as_ref().map(crate::trace::usage),
                "cost_usd": live.cost,
                "ok": live.error.is_none(),
                "error": live.error.as_deref().map(|e| self.trace.text(e)),
                "context": live.context,
            }),
        );
        // Purged: a node's session holds the chat's text, and nothing reads it again.
        let _ = self.port.end_session(&live.id);
        // So is Claude Code's own transcript of it (the whole view, each time),
        // and the slot preset's system prompt (the view's first piece).
        self.delete_transcript(&live.cwd);
        self.wipe_codex(live.slot);
        if live.prompted {
            let _ = self.port.set_system_prompt(&live.preset, "");
        }
        self.slots.give(live.slot);
        let tokens = match live.usage {
            Some(u) => format!(
                "uncached {} cache write {} cache read {} output {}",
                u.input, u.cache_write, u.cache_read, u.output
            ),
            None => "tokens not reported".to_owned(),
        };
        let cost = live.cost.map_or(String::new(), |c| format!(", ${c:.3}"));
        self.say(&format!(
            "compactor node {} ({}, {}): {:.1} s, {} prompt(s), {tokens}{cost}",
            request.node.name(),
            self.spec.harness,
            self.spec.model.as_deref().unwrap_or("default model"),
            live.opened.elapsed().as_secs_f64(),
            live.prompts
        ));
    }
}

fn private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

fn text_block(text: &str) -> Value {
    json!({"type": "text", "text": text})
}

/// The node's first prompt: the system text, the context cut at the view's
/// cache marks (section 8), then the step, one text block each. acpmux
/// forwards text blocks without `cache_control`, so the pieces keep the
/// spec's order and boundaries but carry no breakpoints (README).
pub fn request_blocks(request: &CompactRequest) -> Vec<Value> {
    let mut blocks = vec![text_block(&request.system)];
    blocks.extend(
        optchat_core::cache_pieces(&request.context)
            .into_iter()
            .map(text_block),
    );
    blocks.push(text_block(&request.step));
    blocks
}

/// The compactor presets' harness arguments on a Claude harness: acpmux's
/// allowlist of preset args, every one of which takes a capability away: no
/// tools, no MCP servers, no transcript. The system prompt is the preset's
/// `systemPrompt` text (acpmux writes and checks the file), never a path.
pub const COMPACTOR_ARGS: [&str; 4] = [
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
];

/// The slot presets' system prompt at install, before any node sets its
/// own (acpmux needs some text to take the key, which detects support).
pub const COMPACTOR_PROMPT_SEED: &str = "optchat compactor (each node sets its own system prompt)";

pub use crate::prompt::CachedPrompt;

/// A node's first prompt in the cached layout (`prompt::cached_layout`): the
/// compactor's system text plus the context up to its first cache mark is
/// the session's system prompt, then the rest of the context with one
/// marker at the last mark, then the step.
pub fn cached_prompt(request: &CompactRequest, marker: bool) -> CachedPrompt {
    crate::prompt::cached_layout(&request.system, &request.context, &request.step, marker)
}

/// Whether a failed turn's error is the API's limit of four cache
/// breakpoints ("A maximum of 4 blocks with cache_control may be provided.
/// Found 5."): a Claude Code that places a fourth one of its own.
pub fn is_marker_limit_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("cache_control") && (lower.contains("maximum") || lower.contains("too many"))
}

/// Whether a failed Claude turn's error text is a refusal: Claude Code's
/// refusal messages all link the usage policy (2.1.289: "... safeguards
/// flagged this message (https://www.anthropic.com/legal/aup) ...";
/// older: "... appears to violate our Usage Policy ..."). A usage limit,
/// an overload or a dead process is not one: those are retried.
pub fn is_refusal_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("anthropic.com/legal/aup")
        || lower.contains("usage policy")
        || lower.contains("safeguards flagged")
}

/// Drops a lead-in line ("Here is the line:") before the summary line,
/// which the model or Claude Code sometimes writes. A lead-in ends with a
/// colon and has no other `: ` in it, so a real line ("user: asked:") stays.
pub fn strip_preamble(text: &str) -> String {
    let text = text.trim();
    let lines: Vec<&str> = text.lines().collect();
    let mut start = 0;
    while start + 1 < lines.len() {
        let line = lines[start].trim();
        if line.is_empty() || (line.ends_with(':') && line.len() < 100 && !line.contains(": ")) {
            start += 1;
        } else {
            break;
        }
    }
    if start == 0 {
        return text.to_owned();
    }
    lines[start..].join("\n").trim().to_owned()
}

/// The name Claude Code gives the project directory of `cwd` under its
/// configuration's `projects/`: every character but ASCII letters and
/// digits becomes `-`.
pub fn project_dir_name(cwd: &Path) -> String {
    cwd.to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// Section 4.2 says a compactor call has no tools: the probe fails when the
/// session's Claude Code reports a tool or an MCP server (its `system/init`,
/// which acpmux records as a `session_info_update`), or when the session
/// offers a skill (codex-acp's `available_commands_update`).
pub fn check_isolation(events: &[AcpmuxEvent]) -> Result<(), String> {
    for event in events {
        // Codex lists every skill it loaded as a `$name` command (a user
        // skill, a plugin's, a bundled one); a chat line that names one
        // would pull its text into the node.
        if event.kind == "available_commands_update" {
            let skills: Vec<&str> = event
                .msg
                .get("params")
                .and_then(|p| p.pointer("/update/availableCommands"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|c| c.get("name").and_then(Value::as_str))
                .filter(|name| name.starts_with('$'))
                .collect();
            if !skills.is_empty() {
                return Err(format!(
                    "the compactor session is not isolated: it offers skills [{}]",
                    skills.join(", ")
                ));
            }
            continue;
        }
        if event.kind != "session_info_update" {
            continue;
        }
        let Some(claude) = event
            .msg
            .get("params")
            .and_then(|p| p.pointer("/update/_meta/claude"))
        else {
            continue;
        };
        let names = |key: &str| -> Vec<String> {
            claude
                .get(key)
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    other => other
                        .get("name")
                        .and_then(Value::as_str)
                        .map_or_else(|| other.to_string(), str::to_owned),
                })
                .collect()
        };
        let (tools, servers) = (names("tools"), names("mcp_servers"));
        if !tools.is_empty() || !servers.is_empty() {
            return Err(format!(
                "the compactor session is not isolated: it offers tools [{}] and MCP servers [{}]",
                tools.join(", "),
                servers.join(", ")
            ));
        }
    }
    Ok(())
}

/// The start-up probe of both compactor models: the main one, then the
/// refusal fallback (which nothing else checks until a node is refused).
pub fn probe_models(
    main: &dyn CompactModel,
    fallback: Option<&dyn CompactModel>,
    system: &str,
) -> Result<String, String> {
    let line =
        optchat_host::probe(main, system).map_err(|e| format!("the compactor model: {e}"))?;
    if let Some(fallback) = fallback {
        optchat_host::probe(fallback, system)
            .map_err(|e| format!("the fallback model (for refused nodes): {e}"))?;
    }
    Ok(line)
}

/// The compactor's Claude Code settings (each slot's project settings, and
/// its own configuration's user settings): every tool denied, no
/// auto-memory, no hooks (the user's included), no bundled skills, and a
/// one-day transcript retention for whatever `end` could not delete.
pub fn compactor_settings() -> Value {
    json!({
        "permissions": {"deny": DENIED_TOOLS.as_slice()},
        "autoMemoryEnabled": false,
        "hooks": {},
        "disableAllHooks": true,
        "disableBundledSkills": true,
        "enableAllProjectMcpServers": false,
        "cleanupPeriodDays": TRANSCRIPT_DAYS,
    })
}

/// Creates the compactor's configuration directory (0700) and its settings.
pub fn prepare_config(dir: &Path) -> io::Result<()> {
    private_dir(dir)?;
    write_settings(&dir.join("settings.json"))
}

fn write_settings(path: &Path) -> io::Result<()> {
    crate::session_dir::write_if_changed(
        path,
        format!(
            "{}\n",
            serde_json::to_string_pretty(&compactor_settings()).expect("json")
        )
        .as_bytes(),
    )
}

/// The user's Claude Code home: `CLAUDE_CONFIG_DIR` of the host, else
/// `~/.claude` (where claude-sr puts every session's transcript).
pub fn user_claude_home() -> PathBuf {
    if let Some(dir) = crate::cli::env("CLAUDE_CONFIG_DIR") {
        return PathBuf::from(dir);
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into())
        .join(".claude")
}

/// The acpmux preset of compactor slot `k` (`<base>-slot-<k>`). One preset
/// per slot: a node sets its slot preset's system prompt just before its
/// session starts, and no other node uses that slot meanwhile.
pub fn slot_preset(base: &str, k: usize) -> String {
    format!("{base}-slot-{k}")
}

/// The compactor's acpmux presets (`optchat-compact-<home id>-slot-<k>`, one
/// per JOBS slot), which every compactor session requires.
/// OPTCHAT_CHIEF_ISOLATE=0 does not touch them.
pub fn compactor_presets(paths: &Paths, home: &Path, harness: &str, family: Family) -> Vec<Preset> {
    let base = format!("optchat-compact-{}", home_id(home));
    if family == Family::Codex {
        // Codex: the slot's own CODEX_HOME and the Chief's compactor cache key.
        return (0..optchat_core::JOBS)
            .map(|k| Preset {
                name: slot_preset(&base, k),
                harness: harness.to_owned(),
                env: BTreeMap::from([
                    (
                        "CODEX_HOME".to_owned(),
                        codex_slot_home(&paths.compactor_codex, k)
                            .display()
                            .to_string(),
                    ),
                    (
                        CODEX_CACHE_KEY_ENV.to_owned(),
                        codex_cache_key(home, "compact"),
                    ),
                ]),
                args: Vec::new(),
                system_prompt: None,
            })
            .collect();
    }
    let mut env = BTreeMap::new();
    env.insert(
        "CLAUDE_CONFIG_DIR".to_owned(),
        paths.compactor_config.display().to_string(),
    );
    for key in [
        "CLAUDE_CODE_DISABLE_AUTO_MEMORY",
        "CLAUDE_CODE_DISABLE_CLAUDE_MDS",
        "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS",
        // A refusal must reach the host, whose fallback model is probed.
        "CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK",
    ] {
        env.insert(key.to_owned(), "1".to_owned());
    }
    // Claude Code flags and system prompts: a Claude harness only (claude,
    // claude-sr, ...); another harness keeps the old layout.
    let claude = family == Family::Claude;
    (0..optchat_core::JOBS)
        .map(|k| Preset {
            name: slot_preset(&base, k),
            harness: harness.to_owned(),
            env: env.clone(),
            args: if claude {
                COMPACTOR_ARGS.iter().map(|a| (*a).to_owned()).collect()
            } else {
                Vec::new()
            },
            system_prompt: claude.then(|| COMPACTOR_PROMPT_SEED.to_owned()),
        })
        .collect()
}

/// How the compactor's sessions start for `home`.
pub fn compactor_spec(
    paths: &Paths,
    home: &Path,
    harness: &str,
    family: Family,
    model: Option<&str>,
) -> CompactorSpec {
    let name = format!("optchat-compact-{}", home_id(home));
    CompactorSpec {
        work: std::env::temp_dir().join(&name),
        transcript_dirs: vec![paths.compactor_config.clone(), user_claude_home()],
        preset: name.clone(),
        name,
        harness: harness.to_owned(),
        family,
        codex_home: paths.compactor_codex.clone(),
        model: model.map(str::to_owned),
        effort: None,
        timeout: CALL_TIMEOUT,
        chief: home_id(home),
    }
}

/// The env the cmux codex fork reads its `prompt_cache_key` from (in
/// place of the thread id, which is new for every acpmux session).
pub const CODEX_CACHE_KEY_ENV: &str = "CODEX_PROMPT_CACHE_KEY";

/// The Chief's codex `prompt_cache_key` for `role` (`turn`, `compact`):
/// `optchat-<home id>-<role>`. One key per prefix family, so every turn
/// (and every node) of one Chief lands on the cache the one before wrote.
pub fn codex_cache_key(home: &Path, role: &str) -> String {
    format!("optchat-{}-{role}", home_id(home))
}

/// Compactor slot `k`'s own `CODEX_HOME` under `base`.
pub fn codex_slot_home(base: &Path, k: usize) -> PathBuf {
    base.join(format!("slot-{k}"))
}

/// The user's codex home: `CODEX_HOME` of the host, else `~/.codex`.
pub fn user_codex_home() -> PathBuf {
    if let Some(dir) = crate::cli::env("CODEX_HOME") {
        return PathBuf::from(dir);
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into())
        .join(".codex")
}

/// Top-level keys of the user's codex config.toml a compactor slot keeps:
/// where its requests go (the team subrouter) and the model it asks for.
/// Nothing else: no MCP servers, profiles, hooks, notify, projects,
/// plugins or skills.
pub const CODEX_KEPT_KEYS: [&str; 8] = [
    "model",
    "model_provider",
    "model_providers",
    "openai_base_url",
    "chatgpt_base_url",
    "service_tier",
    "model_reasoning_effort",
    "model_verbosity",
];

/// A compactor slot's codex config.toml: the routing and model keys of the
/// user's (`user`, its text), then the isolation: no project AGENTS.md, no
/// skills (none loaded, none listed in the prompt), no apps, plugins,
/// memories, hooks, subagents or code mode, no history file.
pub fn codex_compactor_config(user: Option<&str>) -> Result<String, String> {
    let mut out = toml::Table::new();
    if let Some(text) = user {
        let table: toml::Table = text
            .parse()
            .map_err(|e| format!("reading the user's codex config.toml: {e}"))?;
        for key in CODEX_KEPT_KEYS {
            if let Some(value) = table.get(key) {
                out.insert(key.to_owned(), value.clone());
            }
        }
    }
    let isolation: toml::Table = r#"
project_doc_max_bytes = 0
suppress_unstable_features_warning = true

[history]
persistence = "none"

[features]
apps = false
plugins = false
memories = false
hooks = false
multi_agent = false
code_mode = false
skip_host_skill_discovery = true

[skills]
include_instructions = false

[skills.bundled]
enabled = false
"#
    .parse()
    .expect("the isolation table parses");
    out.extend(isolation);
    toml::to_string(&out).map_err(|e| format!("writing the compactor's codex config: {e}"))
}

/// Creates every compactor slot's `CODEX_HOME` (0700) under
/// `paths.compactor_codex` with `codex_compactor_config` of the user's
/// config.toml in `user_home`, and empties it (`wipe_codex_home`). When the
/// user has an auth.json, the slot's is a symlink to it: codex-acp refuses
/// a session without a sign-in (checked live 2026-10-04), and a copy whose
/// token refresh rotated the refresh token would sign the user out; codex
/// writes auth.json in place, so a refresh through the link updates the
/// user's own file.
pub fn prepare_codex_homes(paths: &Paths, user_home: &Path) -> Result<(), String> {
    let user = match std::fs::read_to_string(user_home.join("config.toml")) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("reading {}: {e}", user_home.display())),
    };
    let config = codex_compactor_config(user.as_deref())?;
    private_dir(&paths.compactor_codex)
        .map_err(|e| format!("creating {}: {e}", paths.compactor_codex.display()))?;
    let id = chief_installation_id(&paths.compactor_codex)
        .map_err(|e| format!("the compactor's codex installation id: {e}"))?;
    for k in 0..optchat_core::JOBS {
        let dir = codex_slot_home(&paths.compactor_codex, k);
        let made = private_dir(&dir)
            .and_then(|()| wipe_codex_home(&dir))
            .and_then(|()| {
                crate::session_dir::write_if_changed(&dir.join("config.toml"), config.as_bytes())
            })
            .and_then(|()| {
                crate::session_dir::write_if_changed(&dir.join("installation_id"), id.as_bytes())
            });
        made.map_err(|e| format!("preparing {}: {e}", dir.display()))?;
        link_auth(&dir, user_home).map_err(|e| format!("preparing {}: {e}", dir.display()))?;
    }
    Ok(())
}

/// The installation id every codex compactor slot sends: the subrouter
/// keeps one installation id on one account, and OpenAI's prompt cache is
/// per account, so slots with their own ids never read each other's prefix
/// (checked live 2026-10-04: 0 of 31.5k tokens with two ids, 30,464 with
/// one). Kept in `<base>/installation_id`, made once (a version 4 UUID, as
/// codex makes its own).
pub fn chief_installation_id(base: &Path) -> io::Result<String> {
    let path = base.join("installation_id");
    if let Ok(text) = std::fs::read_to_string(&path) {
        let id = text.trim();
        if is_uuid(id) {
            return Ok(id.to_owned());
        }
    }
    let mut bytes = [0u8; 16];
    {
        use std::io::Read;
        std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let id = format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    );
    crate::session_dir::write_if_changed(&path, id.as_bytes())?;
    Ok(id)
}

fn is_uuid(text: &str) -> bool {
    text.len() == 36
        && text.char_indices().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

/// Points `<dir>/auth.json` at the user's auth.json, or removes it when the
/// user has none.
fn link_auth(dir: &Path, user_home: &Path) -> io::Result<()> {
    let link = dir.join("auth.json");
    let target = user_home.join("auth.json");
    if std::fs::read_link(&link).is_ok_and(|t| t == target) && target.exists() {
        return Ok(());
    }
    match std::fs::remove_file(&link) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    if target.exists() {
        std::os::unix::fs::symlink(&target, &link)?;
    }
    Ok(())
}

/// Files of a compactor `CODEX_HOME` that hold no chat text and survive
/// `wipe_codex_home`: its configuration, the link to the user's sign-in,
/// the Chief's installation id and codex's model catalog cache.
pub const CODEX_KEPT_FILES: [&str; 5] = [
    "config.toml",
    "auth.json",
    "installation_id",
    "models_cache.json",
    "version.json",
];

/// Removes everything in a compactor `CODEX_HOME` but `CODEX_KEPT_FILES`:
/// the node's rollout (`sessions/`), thread and log databases, history,
/// shell snapshots, the bundled skills codex unpacks.
pub fn wipe_codex_home(dir: &Path) -> io::Result<()> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        if CODEX_KEPT_FILES.iter().any(|k| name == *k) {
            continue;
        }
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            std::fs::remove_dir_all(&path)?;
        } else {
            std::fs::remove_file(&path)?;
        }
    }
    Ok(())
}

/// Which model builds the compactor's nodes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompactRoute {
    /// A deny-all acpmux session per node (the harness's own sign-in).
    Acpmux,
    /// The Messages API at `OPTCHAT_ANTHROPIC_BASE_URL` with a real key.
    Api,
}

impl CompactRoute {
    pub fn name(self) -> &'static str {
        match self {
            CompactRoute::Acpmux => "acpmux",
            CompactRoute::Api => "api",
        }
    }
}

/// `OPTCHAT_COMPACTOR` when set (`acpmux` or `api`); else acpmux on the
/// team subrouter or without a real key, the Messages API on a configured
/// endpoint with a key.
pub fn compact_route(choice: Option<&str>, config: &Config) -> Result<CompactRoute, String> {
    match choice {
        Some("acpmux") => Ok(CompactRoute::Acpmux),
        Some("api") => Ok(CompactRoute::Api),
        Some(other) => Err(format!("OPTCHAT_COMPACTOR={other}: use acpmux or api")),
        // Purely local ACP: the Messages API only when asked for.
        None => {
            let _ = config;
            Ok(CompactRoute::Acpmux)
        }
    }
}
