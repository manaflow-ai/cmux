//! The compactor's model through acpmux (as mux/host/src/compactor.ts does):
//! the team subrouter serves Claude Code clients and answers raw Messages
//! API calls with 429, so on the subrouter each node is built by the normal
//! harness (claude-sr) in its own acpmux session, never by a request that
//! pretends to be Claude Code.
//!
//! One node, one session: `deny-all`, no tools, the compactor's private
//! directory as cwd, and the turn sessions' isolation preset (their own
//! `CLAUDE_CONFIG_DIR`, no auto-memory), which `Acpmux` applies to every
//! session it starts. The request maps onto the session's prompts: the
//! system text, the context pieces and the step as one prompt, each size
//! loop retry as the next prompt in the same session, the reply text as the
//! line. `end` (after the node is built or failed) kills the session with
//! purge. At most `jobs` sessions live at once.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{RecvTimeoutError, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use optchat_host::{
    CompactModel, CompactRequest, Config, DEFAULT_BASE_URL, Followup, ModelError, NodeId,
    PROBE_NODE, Reply, SUBROUTER_KEY,
};
use serde_json::{Value, json};

use crate::acpmux::{AgentPort, SessionSpec, TurnSignal};
use crate::fold::TurnFold;

/// The permission policy of every compactor session: a node needs no tool.
pub const POLICY: &str = "deny-all";

/// Longest one compactor prompt may take, the session's start included.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(300);

/// Claude Code's built-in tools, denied in the compactor directory's
/// project settings so the harness does not offer them (section 4.2: no
/// tools). The `deny-all` policy refuses any call that still happens.
const DENIED_TOOLS: [&str; 20] = [
    "Agent",
    "Bash",
    "BashOutput",
    "Edit",
    "ExitPlanMode",
    "Glob",
    "Grep",
    "KillShell",
    "LS",
    "MultiEdit",
    "NotebookEdit",
    "NotebookRead",
    "Read",
    "SlashCommand",
    "Skill",
    "Task",
    "TodoWrite",
    "WebFetch",
    "WebSearch",
    "Write",
];

/// How compactor sessions start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompactorSpec {
    /// Session names are `<name>-<node>` (`<name>-probe` for the probe).
    pub name: String,
    /// The private, empty working directory (`prepare_dir`).
    pub cwd: PathBuf,
    pub harness: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    /// Longest one prompt may take.
    pub timeout: Duration,
    /// Most sessions alive at once (the core's JOBS).
    pub jobs: usize,
}

/// A node's open session.
struct Live {
    id: String,
    /// The last event seq already read.
    seq: u64,
}

pub struct AcpmuxCompactor {
    port: Arc<dyn AgentPort>,
    spec: CompactorSpec,
    live: Mutex<HashMap<NodeId, Live>>,
    /// Sessions alive, at most `spec.jobs`.
    slots: Mutex<usize>,
    freed: Condvar,
    prompts: AtomicU64,
    /// Makes prompt ids unique across host starts (acpmux runs an id once).
    stamp: u64,
}

impl AcpmuxCompactor {
    pub fn new(port: Arc<dyn AgentPort>, spec: CompactorSpec) -> AcpmuxCompactor {
        AcpmuxCompactor {
            port,
            spec,
            live: Mutex::new(HashMap::new()),
            slots: Mutex::new(0),
            freed: Condvar::new(),
            prompts: AtomicU64::new(0),
            stamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_millis() as u64),
        }
    }

    fn session_name(&self, node: NodeId) -> String {
        if node == PROBE_NODE {
            format!("{}-probe", self.spec.name)
        } else {
            format!("{}-{}", self.spec.name, node.name())
        }
    }

    fn take_slot(&self) {
        let mut used = self.slots.lock().expect("slots");
        while *used >= self.spec.jobs.max(1) {
            used = self.freed.wait(used).expect("slots");
        }
        *used += 1;
    }

    fn free_slot(&self) {
        let mut used = self.slots.lock().expect("slots");
        *used = used.saturating_sub(1);
        drop(used);
        self.freed.notify_one();
    }

    /// Opens the node's session (a slot first, so at most `jobs` live).
    fn open(&self, node: NodeId) -> Result<String, ModelError> {
        self.take_slot();
        let name = self.session_name(node);
        // Left by a host that stopped while the node was being built.
        if let Ok(Some(old)) = self.port.find(&name) {
            let _ = self.port.end_session(&old);
        }
        let spec = SessionSpec {
            name,
            cwd: self.spec.cwd.clone(),
            harness: self.spec.harness.clone(),
            policy: POLICY.to_owned(),
            model: self.spec.model.clone(),
            effort: self.spec.effort.clone(),
        };
        match self.port.new_session(&spec) {
            Ok(id) => {
                self.live.lock().expect("live").insert(
                    node,
                    Live {
                        id: id.clone(),
                        seq: 0,
                    },
                );
                Ok(id)
            }
            Err(e) => {
                self.free_slot();
                Err(ModelError::new(format!(
                    "starting a compactor session: {e}"
                )))
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
        let answer = answer.map_err(|e| ModelError::new(format!("compactor session: {e}")))?;
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
        Ok(Reply::text(fold.final_text().unwrap_or_default()))
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
        self.free_slot();
    }
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

/// The compactor sessions' working directory: private (0700) and empty but
/// for the project settings that deny the harness's tools.
pub fn prepare_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    let claude = dir.join(".claude");
    std::fs::create_dir_all(&claude)?;
    let settings = json!({
        "permissions": {"deny": DENIED_TOOLS},
        "enableAllProjectMcpServers": false,
    });
    crate::session_dir::write_if_changed(
        &claude.join("settings.json"),
        format!(
            "{}\n",
            serde_json::to_string_pretty(&settings).expect("json")
        )
        .as_bytes(),
    )
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
