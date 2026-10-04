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
//! with instruction files. The request maps onto the session's prompts: the
//! system text, the context pieces and the step as one prompt, each size
//! loop retry as the next prompt in the same session, the reply text as the
//! line. `end` (after the node is built or failed) kills the session with
//! purge, deletes its Claude Code transcript and logs its seconds and token
//! use. At most JOBS sessions live at once across the main and fallback
//! compactors (one `Slots` gate).

use std::collections::{BTreeMap, HashMap};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{RecvTimeoutError, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::acp::AcpmuxEvent;
use optchat_host::{
    CompactModel, CompactRequest, Config, DEFAULT_BASE_URL, Followup, ModelError, NodeId,
    PROBE_NODE, Reply, SUBROUTER_KEY,
};
use serde_json::{Value, json};

use crate::acpmux::{AgentPort, Preset, SessionSpec, TurnSignal};
use crate::fold::{TurnFold, Usage};
use crate::paths::{Paths, home_id};

/// The permission policy of every compactor session: a node needs no tool.
pub const POLICY: &str = "deny-all";

/// Longest one compactor prompt may take, the session's start included.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(300);

/// Days Claude Code keeps a compactor transcript that `end` could not
/// delete (a crash); its minimum.
pub const TRANSCRIPT_DAYS: u64 = 1;

/// Claude Code's built-in tools, denied in the compactor's own user
/// settings so the harness does not offer them (section 4.2: no tools).
/// The interactive ones matter most: acpmux keeps questions and plan
/// approval for a human under every policy, so one call would hang the
/// node (and, under rule 3, every turn) until `CALL_TIMEOUT`. The
/// `deny-all` policy refuses any call that still happens, and the start-up
/// probe reports any tool or MCP server the session still offers.
pub const DENIED_TOOLS: [&str; 45] = [
    "Agent",
    "AskUserQuestion",
    "Bash",
    "BashOutput",
    "CronCreate",
    "CronDelete",
    "CronList",
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
    "ListMcpResourcesTool",
    "Monitor",
    "MultiEdit",
    "NotebookEdit",
    "NotebookRead",
    "PushNotification",
    "Read",
    "ReadMcpResourceTool",
    "RemoteTrigger",
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
    /// The compactor's `CLAUDE_CONFIG_DIR`; a node's transcript under its
    /// `projects/` is deleted when the node ends.
    pub config_dir: PathBuf,
    /// The acpmux preset every compactor session requires.
    pub preset: String,
    pub harness: String,
    pub model: Option<String>,
    /// acpmux's `effort`; None (the harness default) until verified live.
    pub effort: Option<String>,
    /// Longest one prompt may take.
    pub timeout: Duration,
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
    opened: Instant,
    prompts: u32,
    /// Token use the harness reported, summed over the node's prompts.
    usage: Option<Usage>,
    cost: Option<f64>,
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
    log: Option<Log>,
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
            log: None,
        }
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

    /// The slot's working directory, created, by its real path (Claude
    /// Code names the project directory after the real path).
    fn slot_dir(&self, slot: usize) -> io::Result<PathBuf> {
        private_dir(&self.spec.work)?;
        let dir = self.spec.work.join(format!("slot-{slot}"));
        private_dir(&dir)?;
        std::fs::canonicalize(&dir)
    }

    /// Opens the node's session (a slot first, so at most JOBS live).
    fn open(&self, node: NodeId) -> Result<String, ModelError> {
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
        // A transcript left by a crash in this slot.
        self.delete_transcript(&cwd);
        let name = self.session_name(node);
        // Left by a host that stopped while the node was being built.
        if let Ok(Some(old)) = self.port.find(&name) {
            let _ = self.port.end_session(&old);
        }
        let spec = SessionSpec {
            name,
            cwd: cwd.clone(),
            harness: self.spec.harness.clone(),
            policy: POLICY.to_owned(),
            model: self.spec.model.clone(),
            effort: self.spec.effort.clone(),
            preset: Some(self.spec.preset.clone()),
        };
        match self.port.new_session(&spec) {
            Ok(id) => {
                self.live.lock().expect("live").insert(
                    node,
                    Live {
                        id: id.clone(),
                        seq: 0,
                        slot,
                        cwd,
                        opened: Instant::now(),
                        prompts: 0,
                        usage: None,
                        cost: None,
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
        let dir = self
            .spec
            .config_dir
            .join("projects")
            .join(project_dir_name(cwd));
        if dir.exists()
            && let Err(e) = std::fs::remove_dir_all(&dir)
        {
            self.say(&format!(
                "deleting the compactor transcript {}: {e}",
                dir.display()
            ));
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
        if let Some(u) = answer.pointer("/_meta/claude/usage").and_then(Usage::parse) {
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

impl CompactModel for AcpmuxCompactor {
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        let node = request.node;
        let (session, blocks) = match followups.last() {
            None => {
                // A fresh conversation: whatever an earlier try left is gone.
                self.end(request);
                (self.open(node)?, request_blocks(request))
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

    fn end(&self, request: &CompactRequest) {
        let Some(live) = self.live.lock().expect("live").remove(&request.node) else {
            return;
        };
        // Purged: a node's session holds the chat's text, and nothing reads it again.
        let _ = self.port.end_session(&live.id);
        // So is Claude Code's own transcript of it (the whole view, each time).
        self.delete_transcript(&live.cwd);
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
            "compactor node {} ({}): {:.1} s, {} prompt(s), {tokens}{cost}",
            request.node.name(),
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
/// which acpmux records as a `session_info_update`).
pub fn check_isolation(events: &[AcpmuxEvent]) -> Result<(), String> {
    for event in events {
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

/// The compactor's own Claude Code user settings: every tool denied, no
/// auto-memory, no hooks, no bundled skills, and a one-day transcript
/// retention for whatever `end` could not delete.
pub fn compactor_settings() -> Value {
    json!({
        "permissions": {"deny": DENIED_TOOLS.as_slice()},
        "autoMemoryEnabled": false,
        "hooks": {},
        "disableBundledSkills": true,
        "enableAllProjectMcpServers": false,
        "cleanupPeriodDays": TRANSCRIPT_DAYS,
    })
}

/// Creates the compactor's configuration directory (0700) and its settings.
pub fn prepare_config(dir: &Path) -> io::Result<()> {
    private_dir(dir)?;
    crate::session_dir::write_if_changed(
        &dir.join("settings.json"),
        format!(
            "{}\n",
            serde_json::to_string_pretty(&compactor_settings()).expect("json")
        )
        .as_bytes(),
    )
}

/// The compactor's acpmux preset (`optchat-compact-<home id>`), which every
/// compactor session requires. OPTCHAT_CHIEF_ISOLATE=0 does not touch it.
pub fn compactor_preset(paths: &Paths, home: &Path, harness: &str) -> Preset {
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
    Preset {
        name: format!("optchat-compact-{}", home_id(home)),
        harness: harness.to_owned(),
        env,
    }
}

/// How the compactor's sessions start for `home`.
pub fn compactor_spec(paths: &Paths, home: &Path, harness: &str, model: &str) -> CompactorSpec {
    let name = format!("optchat-compact-{}", home_id(home));
    CompactorSpec {
        work: std::env::temp_dir().join(&name),
        config_dir: paths.compactor_config.clone(),
        preset: name.clone(),
        name,
        harness: harness.to_owned(),
        model: Some(model.to_owned()),
        effort: None,
        timeout: CALL_TIMEOUT,
    }
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
        None => {
            let subrouter = config.base_url.trim_end_matches('/') == DEFAULT_BASE_URL;
            if subrouter || config.api_key == SUBROUTER_KEY {
                Ok(CompactRoute::Acpmux)
            } else {
                Ok(CompactRoute::Api)
            }
        }
    }
}
