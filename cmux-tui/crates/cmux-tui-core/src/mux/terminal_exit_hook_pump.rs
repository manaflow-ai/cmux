//! The exit hook pump (`terminal-exit-hooks-v1`, state/terminal_exit_hooks.rs):
//! one daemon thread that fires each armed hook once its terminal's process
//! ends. It wakes on a terminal's durable exit (the same wake as
//! `terminal.wait_exit`'s waiters, terminal_exit.rs), on a hook armed (one
//! whose job already ended fires at once) and at the daemon's start (hooks a
//! restart left armed). There is no timer and no poll: an idle pump waits on
//! its channel. Each firing reads the terminal's durable exit receipt, so the
//! status is exact (a signal is a signal), and every step is keyed by the
//! hook id: a notice (`notification.create`'s durable effect), an agent
//! message (`agent.message.send`, as the actor that armed the hook; the
//! agent message pump delivers it), then the hook's end. A crash between
//! steps replays the same keys and does nothing twice.

use std::collections::HashSet;
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, Weak};

use serde_json::{Value, json};

use super::Mux;
use crate::NotificationLevel;
use crate::mux::NotificationSource;
use crate::resource::{ResourceError, TerminalPublicId};
use crate::state::agent_message_store::NewAgentMessage;
use crate::state::commit::StateEffects;
use crate::state::store::StateChanges;
use crate::state::terminal_exit_hook_store::{self as store, ArmedExitHook, ExitHookFiring};
use crate::state::terminal_exit_hooks::{DEFAULT_TEXT, DEFAULT_TITLE, ExitReport};
use crate::workspace_registry::{Actor, WorkspaceMutation};

const ORIGIN: &str = "terminal-exit-hooks";
/// Armed hooks one pass reads (the store holds at most this many).
const PAGE: i64 = store::MAX_ARMED;
const THREAD_STACK_BYTES: usize = 256 * 1024;

/// The pump's wake, and which terminals ended since its last pass.
#[derive(Default)]
pub(crate) struct TerminalExitHookPump {
    wake: Mutex<Option<SyncSender<()>>>,
    /// Terminals whose exit (or a new hook) woke the pump since its last pass.
    ended: Mutex<Option<HashSet<String>>>,
    /// Whether the next pass reads every armed hook.
    everything: Mutex<bool>,
}

impl Mux {
    /// Starts the pump thread (once) and fires what a restart left armed.
    pub fn start_terminal_exit_hooks(self: &Arc<Self>) {
        let (wake, woken) = sync_channel(1);
        {
            let mut slot =
                self.terminal_exit_hook_pump.wake.lock().unwrap_or_else(|e| e.into_inner());
            if slot.is_some() {
                return;
            }
            *slot = Some(wake);
        }
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("mux-terminal-exit-hooks".into())
            .stack_size(THREAD_STACK_BYTES)
            .spawn(move || run(&mux, &woken));
        if spawned.is_err() {
            self.report_internal_diagnostic("terminal exit hook pump not started");
            return;
        }
        self.wake_terminal_exit_hooks(None);
    }

    /// Asks the pump for a pass over `terminal`'s armed hooks (every armed
    /// hook for `None`). Cheap: it runs on every terminal exit.
    pub(crate) fn wake_terminal_exit_hooks(&self, terminal: Option<&str>) {
        let pump = &self.terminal_exit_hook_pump;
        // Before the pump starts nothing is noted: its first pass reads
        // every armed hook anyway.
        if pump.wake.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            return;
        }
        match terminal {
            Some(terminal) => {
                pump.ended
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .get_or_insert_with(HashSet::new)
                    .insert(terminal.to_owned());
            }
            None => *pump.everything.lock().unwrap_or_else(|e| e.into_inner()) = true,
        }
        if let Some(wake) = &*pump.wake.lock().unwrap_or_else(|e| e.into_inner()) {
            let _ = wake.try_send(());
        }
    }

    /// One pass: fires each armed hook (of the terminals that woke it, or
    /// all) whose terminal ended.
    fn fire_terminal_exit_hooks(&self) {
        let pump = &self.terminal_exit_hook_pump;
        let everything =
            std::mem::take(&mut *pump.everything.lock().unwrap_or_else(|e| e.into_inner()));
        let ended = pump.ended.lock().unwrap_or_else(|e| e.into_inner()).take().unwrap_or_default();
        if !everything && ended.is_empty() {
            return;
        }
        let armed =
            match self.read_registry_state(|connection| store::armed_hooks(connection, PAGE)) {
                Ok(armed) => armed,
                Err(_) => {
                    self.report_internal_diagnostic("terminal exit hooks unreadable");
                    return;
                }
            };
        for hook in armed {
            if !everything && !ended.contains(&hook.hook.terminal_id) {
                continue;
            }
            if let Some(outcome) = self.ended_outcome(&hook.hook.terminal_id) {
                self.fire_terminal_exit_hook(hook, &outcome);
            }
        }
    }

    /// The durable exit outcome of `terminal`, once its process ended; a
    /// terminal closed before an exit was recorded ended with no status.
    fn ended_outcome(&self, terminal: &str) -> Option<Value> {
        let closed = || json!({"kind": "unknown", "reason": "the terminal was closed"});
        let Ok(id) = TerminalPublicId::parse(terminal.to_owned()) else { return Some(closed()) };
        match self.terminal_exit_state(&id) {
            Ok(state) if state.get("state").and_then(Value::as_str) == Some("exited") => {
                Some(state.get("outcome").cloned().unwrap_or(Value::Null))
            }
            Ok(_) => None,
            Err(error)
                if error
                    .downcast_ref::<ResourceError>()
                    .is_some_and(|error| error.code == "terminal.closed")
                    || error.to_string().contains("is not live") =>
            {
                Some(closed())
            }
            // A registry read that failed now may work at the next wake.
            Err(_) => None,
        }
    }

    fn fire_terminal_exit_hook(&self, armed: ArmedExitHook, outcome: &Value) {
        let hook = &armed.hook;
        let actor = Actor::from_wire(&hook.actor);
        let report = ExitReport::of(outcome);
        let name = hook.label.as_deref().unwrap_or(&hook.terminal_id);
        let mut errors: Vec<String> = Vec::new();
        let mut notification_id = armed.notification_id.clone();
        if hook.notify && notification_id.is_none() {
            let title = report.render(
                hook.title.as_deref().unwrap_or(DEFAULT_TITLE),
                name,
                &hook.terminal_id,
            );
            let surface = TerminalPublicId::parse(hook.terminal_id.clone())
                .ok()
                .and_then(|terminal| self.resource_surface_for_terminal(&terminal));
            let level =
                if report.success { NotificationLevel::Info } else { NotificationLevel::Warning };
            match self.create_durable_notification_identified(
                &actor,
                &format!("exit-hook-{}-notice", hook.id),
                title,
                None,
                report.status.clone(),
                level,
                surface,
                NotificationSource::Daemon,
                true,
            ) {
                Ok((_, id)) => {
                    notification_id = id;
                    self.note_exit_hook_step(&hook.id, notification_id.as_deref(), None);
                }
                Err(error) => errors.push(format!("the notice failed: {error:#}")),
            }
        }
        let mut message_id = armed.message_id.clone();
        if let Some(recipient) = &hook.send_to
            && message_id.is_none()
        {
            let body = report.render(
                hook.text.as_deref().unwrap_or(DEFAULT_TEXT),
                name,
                &hook.terminal_id,
            );
            let sent =
                WorkspaceMutation::new(format!("exit-hook-{}-message", hook.id), ORIGIN, actor)
                    .and_then(|mutation| {
                        self.agent_message_send(
                            &mutation,
                            None,
                            &Mux::ordinary_resource_selectors(),
                            NewAgentMessage {
                                sender: None,
                                sender_name: None,
                                recipients: vec![recipient.clone()],
                                body,
                                thread_id: None,
                                in_reply_to: None,
                            },
                        )
                    });
            match sent {
                Ok(commit) => {
                    message_id = commit.result.get("id").and_then(Value::as_str).map(str::to_owned);
                    self.note_exit_hook_step(&hook.id, None, message_id.as_deref());
                }
                Err(error) => errors.push(format!("the message failed: {error:#}")),
            }
        }
        let firing = ExitHookFiring {
            outcome: outcome.clone(),
            status: report.status,
            notification_id,
            message_id,
            error: (!errors.is_empty()).then(|| errors.join("; ")),
        };
        let fingerprint = json!({"operation": "terminal.exit_hook.fire", "hook": hook.id});
        let ended = self.commit_state(
            &WorkspaceMutation::daemon_local(ORIGIN),
            "terminal.exit_hook.fire",
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                store::finish_hook(transaction, &hook.id, &firing, crate::mux::now_ms())?;
                Ok(StateChanges::new(Value::Null, Vec::new()))
            },
        );
        if ended.is_err() {
            self.report_internal_diagnostic("terminal exit hook end not recorded");
        }
    }

    /// Records a finished step, best effort: a lost note only means a
    /// replay of the same key after a crash.
    fn note_exit_hook_step(&self, hook: &str, notification: Option<&str>, message: Option<&str>) {
        let fingerprint = json!({"operation": "terminal.exit_hook.step", "hook": hook,
            "notification": notification, "message": message});
        let noted = self.commit_state(
            &WorkspaceMutation::daemon_local(ORIGIN),
            "terminal.exit_hook.step",
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                store::note_step(transaction, hook, notification, message)?;
                Ok(StateChanges::new(Value::Null, Vec::new()))
            },
        );
        if noted.is_err() {
            self.report_internal_diagnostic("terminal exit hook step not recorded");
        }
    }
}

fn run(mux: &Weak<Mux>, woken: &Receiver<()>) {
    while woken.recv().is_ok() {
        let Some(mux) = mux.upgrade() else { return };
        if mux.shutting_down.load(std::sync::atomic::Ordering::Acquire) {
            return;
        }
        mux.fire_terminal_exit_hooks();
    }
}
