//! Subagents (section 9): `spawn(tasks)` and `tell(id, message)`, served
//! from the host on its tools socket (the MCP server and the `chief`
//! launcher forward to it), so the Chief's harness, whatever it is, uses
//! them like `zoom` and `date`.
//!
//! - `spawn` waits for the view to settle, renders it, and starts one
//!   acpmux session per task (the subagent harness, default the Chief's),
//!   tagged `mux.parent` plus `optchat.spawn` and `optchat.subagent` (never
//!   `cmux.chief`). Its first message is the view, then its task; its system
//!   prompt is section 9's subagent prompt, VIEW_DOC and the user's
//!   instructions (the subagent preset's system prompt on a Claude harness,
//!   else the subagent directory's CLAUDE.md or AGENTS.md). It answers the
//!   ids at once. Each subagent also gets a cmux workspace whose tab is its
//!   chat (workspaces.rs), so the user can watch and join it.
//! - Its tools are zoom and date (its own MCP server says `--role
//!   subagent`), not spawn. Its tool calls stay in its own session.
//! - The brain (brain/spawns.rs) watches the sessions: when all of one
//!   spawn's subagents finished a turn, their reports reach the chat as ONE
//!   `user` message, `[id] report` each.
//!
//! Deviation: `tell` reaches a running subagent after its current turn
//! (acpmux queues the prompt; claude-sr offers no steering), not between its
//! tool calls.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use optchat_host::OptChat;
use serde_json::{Value, json};

use crate::acpmux::{AgentPort, SessionSpec, TurnSignal};
use crate::brain::Input;
use crate::tools::Orchestrator;
use crate::trace::Trace;
use crate::workspaces::Workspaces;

/// The acpmux tag naming a subagent's spawn, and the one naming the
/// subagent (`a<N>`).
pub const SPAWN_TAG: &str = "optchat.spawn";
pub const SUBAGENT_TAG: &str = "optchat.subagent";
/// Most tasks one spawn starts.
pub const MAX_TASKS: usize = 8;
/// Longest `spawn` waits for the view to settle (section 6).
pub const SETTLE_LIMIT: Duration = Duration::from_secs(240);
/// Prompt ids of the host's own prompts to a subagent start with this; any
/// other prompt in its session is the user's (typed into its chat).
pub const PROMPT_PREFIX: &str = "optchat-";

/// What one spawn was given: its id and its subagents' ids.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnPlan {
    pub spawn: String,
    pub ids: Vec<String>,
}

/// How subagent sessions start.
#[derive(Clone, Debug)]
pub struct SubagentSettings {
    pub harness: String,
    pub policy: String,
    pub model: Option<String>,
    /// The subagent preset (required: never a fallback to the turn preset).
    pub preset: Option<String>,
    /// Every subagent's working directory (`optchat/subagent`).
    pub cwd: PathBuf,
    /// Session names are `<prefix>-<id>`.
    pub prefix: String,
    /// The `mux.parent` value (the Chief's children).
    pub parent: String,
    /// Claude harness: the system text for CLAUDE.md when acpmux took no
    /// preset system prompt. None on other harnesses (AGENTS.md is written
    /// at host start).
    pub claude_md: Option<String>,
}

/// A subagent session's tags: `mux.parent`, its spawn and its id.
pub fn tags(parent: &str, spawn: &str, id: &str) -> BTreeMap<String, String> {
    BTreeMap::from([
        (cmux_chief::rules::PARENT_TAG.to_owned(), parent.to_owned()),
        (SPAWN_TAG.to_owned(), spawn.to_owned()),
        (SUBAGENT_TAG.to_owned(), id.to_owned()),
    ])
}

/// Serves `spawn` and `tell` (tools.rs `Orchestrator`).
pub struct Spawner {
    chat: Arc<OptChat>,
    agents: Arc<dyn AgentPort>,
    settings: SubagentSettings,
    tx: Mutex<Sender<Input>>,
    trace: Trace,
    workspaces: Option<Arc<dyn Workspaces>>,
    log: crate::brain::Log,
}

impl Spawner {
    pub fn new(
        chat: Arc<OptChat>,
        agents: Arc<dyn AgentPort>,
        settings: SubagentSettings,
        tx: Sender<Input>,
        log: crate::brain::Log,
    ) -> Spawner {
        Spawner {
            chat,
            agents,
            settings,
            tx: Mutex::new(tx),
            trace: Trace::off(),
            workspaces: None,
            log,
        }
    }

    pub fn with_trace(mut self, trace: Trace) -> Spawner {
        self.trace = trace;
        self
    }

    pub fn with_workspaces(mut self, workspaces: Option<Arc<dyn Workspaces>>) -> Spawner {
        self.workspaces = workspaces;
        self
    }

    fn send(&self, input: Input) -> Result<(), String> {
        self.tx
            .lock()
            .expect("tx")
            .send(input)
            .map_err(|_| "the Chief host is stopping".to_owned())
    }

    /// Starts subagent `id`'s session and first prompt, then its workspace.
    fn start_one(&self, spawn: &str, id: &str, task: &str, view: &str) -> Result<(), String> {
        let began = Instant::now();
        let s = &self.settings;
        // Claude only through acpmux's own Claude Code adapter (harness_gate).
        let admitted =
            crate::harness_gate::admit_live(&*self.agents, &s.harness).map_err(|reason| {
                crate::harness_gate::trace_refusal(&self.trace, "subagent", &s.harness, &reason);
                crate::harness_gate::refusal(&reason)
            })?;
        let spec = SessionSpec {
            name: format!("{}-{id}", s.prefix),
            cwd: s.cwd.clone(),
            harness: admitted.profile.clone(),
            policy: s.policy.clone(),
            model: s.model.clone(),
            effort: None,
            preset: s.preset.clone(),
            tags: tags(&s.parent, spawn, id),
        };
        let session = self.agents.new_session(&spec)?;
        let admitted = crate::harness_gate::session_harness(&*self.agents, &session, &admitted)
            .map_err(|reason| {
                let _ = self.agents.end_session(&session);
                crate::harness_gate::trace_refusal(&self.trace, "subagent", &s.harness, &reason);
                crate::harness_gate::refusal(&reason)
            })?;
        // Registered before its prompt: its turn end can only follow.
        self.send(Input::SubagentStarted {
            id: id.to_owned(),
            session_id: session.clone(),
        })?;
        let (tx, rx) = channel();
        let prompt_id = format!("{PROMPT_PREFIX}sub:{id}:{}", now_ms());
        self.agents.start_prompt(
            &session,
            crate::prompt::subagent_blocks(view, task),
            &prompt_id,
            tx,
        )?;
        self.forward_answer(id, rx);
        self.trace.emit(
            "subagent.start",
            json!({"id": id, "spawn": spawn, "session": session, "harness": s.harness, "harness_profile": admitted.profile, "harness_kind": admitted.kind, "harness_argv0": admitted.argv0, "ms": began.elapsed().as_millis() as u64}),
        );
        // The chat replays its history when the tab attaches, so the
        // workspace can follow the prompt.
        if let Some(workspaces) = &self.workspaces {
            let name = crate::workspaces::name(id, task);
            match workspaces.open(&session, &name, &s.cwd) {
                Ok(key) => {
                    self.trace.emit(
                        "subagent.workspace",
                        json!({"id": id, "spawn": spawn, "workspace": key, "name": name}),
                    );
                    let _ = self.send(Input::SubagentWorkspace {
                        id: id.to_owned(),
                        key,
                        name,
                    });
                }
                Err(e) => {
                    (self.log)(&format!("subagent {id}: opening its workspace: {e}"));
                    self.trace.emit(
                        "subagent.workspace",
                        json!({"id": id, "spawn": spawn, "error": self.trace.text(&e)}),
                    );
                }
            }
        }
        Ok(())
    }

    /// Sends the prompt's answer (token use, cost) to the brain.
    fn forward_answer(&self, id: &str, rx: std::sync::mpsc::Receiver<TurnSignal>) {
        let tx = self.tx.lock().expect("tx").clone();
        let id = id.to_owned();
        std::thread::spawn(move || {
            while let Ok(signal) = rx.recv() {
                match signal {
                    TurnSignal::Changed => {}
                    TurnSignal::Done(answer) => {
                        let _ = tx.send(Input::SubagentAnswer { id, answer });
                        return;
                    }
                    TurnSignal::Lost => return,
                }
            }
        });
    }
}

impl Orchestrator for Spawner {
    fn spawn(&self, tasks: Vec<String>) -> Result<String, String> {
        if tasks.len() > MAX_TASKS {
            return Err(format!(
                "spawn takes at most {MAX_TASKS} tasks; split the work"
            ));
        }
        let began = Instant::now();
        // Section 9: the view at spawn time, after settle.
        if !self.chat.settle(None, Some(SETTLE_LIMIT)) {
            return Err(
                "the memory is still summarizing, so no subagent started; call spawn again".into(),
            );
        }
        let view = self.chat.render_view().text;
        let (reply, answer) = channel();
        self.send(Input::SpawnRegister {
            tasks: tasks.clone(),
            reply,
        })?;
        let plan = answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())??;
        self.trace.emit(
            "spawn",
            json!({
                "spawn": plan.spawn,
                "ids": plan.ids,
                "tasks": tasks.iter().map(|t| self.trace.text(t)).collect::<Vec<_>>(),
                "settle_ms": began.elapsed().as_millis() as u64,
                "view": {"bytes": view.len(), "hash": crate::trace::hash(&view)},
                "harness": self.settings.harness,
            }),
        );
        if let (Some(text), Some(preset)) = (&self.settings.claude_md, &self.settings.preset) {
            let file = (!self.agents.system_prompt(preset)).then_some(text.as_str());
            if let Err(e) = crate::session_dir::set_claude_md(&self.settings.cwd, file) {
                (self.log)(&format!("the subagent directory's CLAUDE.md: {e}"));
            }
        }
        let mut started = Vec::new();
        for (id, task) in plan.ids.iter().zip(&tasks) {
            match self.start_one(&plan.spawn, id, task, &view) {
                Ok(()) => started.push(id.clone()),
                Err(e) => {
                    (self.log)(&format!("subagent {id} did not start: {e}"));
                    let _ = self.send(Input::SubagentFailed {
                        id: id.clone(),
                        error: e.clone(),
                    });
                    started.push(format!("{id} (did not start: {e})"));
                }
            }
        }
        Ok(format!(
            "Started {}, each in its own cmux workspace. When all of them finish, their reports reach you as one message, \"[id] report\" each; never wait or poll for them. tell(id, message) sends one more instructions.",
            started.join(", ")
        ))
    }

    fn tell(&self, id: &str, message: &str) -> Result<String, String> {
        let (reply, answer) = channel();
        self.send(Input::Tell {
            id: id.to_owned(),
            message: message.to_owned(),
            reply,
        })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }
}

/// The answer of a prompt to a subagent: its token use and cost.
pub fn answer_fields(answer: &Result<Value, String>) -> Value {
    match answer {
        Ok(v) => json!({
            "usage": crate::fold::answer_usage(v).map(|(u, _)| crate::trace::usage(&u)),
            "cost_usd": crate::turn::answer_cost(v),
            "stop": v.get("stopReason"),
        }),
        Err(e) => json!({"error": crate::trace::prefix(e)}),
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}
