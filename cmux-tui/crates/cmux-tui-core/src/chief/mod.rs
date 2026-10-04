//! The Chief's daemon shell (plans/cmux-next/chief-mac.md sections 2 and 3):
//! an in-process actor in the session daemon around the sans-I/O brain core
//! (`cmux-chief`). It is a client of two owners and listens on nothing:
//!
//! - the local conversation owner, in process: writes go straight to the
//!   store as `agent_mux` (the owner stamps the agent principal; no socket,
//!   no minted token), and `conversation-changed` comes from the mux event bus;
//! - the acpmux hub, through [`AgentConnector`] (the daemon binary supplies
//!   the acpmux client; tests supply a fake).
//!
//! NOT WIRED YET (gate): the daemon binary must not start this shell before
//! it writes the Chief's session directory (CLAUDE.md, `.claude/settings.json`
//! with the memory hooks, the tool servers; chief-mac.md section 7 step 4).
//! The first connect creates the durable acpmux session `mux` in that
//! directory, so a start without it makes a Chief with no prompt and no tools.
//! `CHIEF_CAPABILITY` is advertised only by that wiring.
//!
//! One actor per `$MUX_HOME`: it holds the same kernel lock as the
//! TypeScript host (`state/host.lock`), so the two hosts never run together,
//! and it reads and writes the same `state/host.json`.
//!
//! Every hub request has the request deadline: a read that misses it fails
//! (the core gets the failure input) and its connection is closed, so the
//! loop connects again. A prompt's request answers only when its turn ends
//! (no bound), so its deadline is on the hub's acknowledgment
//! (`_acpmux/prompt_accepted`) instead. All times come from one wall clock
//! (`actor::now_ms`): the core's `now`, its timers and the deadlines.

mod actor;
mod agent;
mod agent_loop;
mod daemon_port;
mod lock;
mod state_file;
#[cfg(test)]
mod tests;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

pub use agent::{AgentConnection, AgentConnector, AgentError, AgentNotice, AgentReply};
pub use lock::LockError;

use crate::Mux;
use actor::{Actor, Msg};
use agent::{Backoff, SessionSpec};
use agent_loop::{AgentLoop, Ctl, Current};

/// The capability the session daemon advertises when it runs the Chief.
pub const CHIEF_CAPABILITY: &str = "chief-v1";

/// Where and how the Chief runs.
#[derive(Clone)]
pub struct ChiefConfig {
    /// `$MUX_HOME` (the TypeScript host's default is `~/.cmux/mux`).
    pub mux_home: PathBuf,
    /// The Mac user's display name (participant `user_local`).
    pub display_name: String,
    /// The Chief session's acpmux harness and policy.
    pub harness: String,
    pub policy: String,
    /// The deadline of one hub request (not a prompt) and of one connect.
    pub request_timeout: Duration,
    pub backoff_initial: Duration,
    pub backoff_max: Duration,
    pub log: Arc<dyn Fn(&str) + Send + Sync>,
}

impl ChiefConfig {
    /// The TypeScript host's defaults (30 s requests, 0.5-30 s backoff).
    pub fn new(mux_home: PathBuf, display_name: String) -> Self {
        Self {
            mux_home,
            display_name,
            harness: "claude-sr".to_owned(),
            policy: "approve-all".to_owned(),
            request_timeout: Duration::from_secs(30),
            backoff_initial: Duration::from_millis(500),
            backoff_max: Duration::from_secs(30),
            log: Arc::new(|line| eprintln!("chief: {line}")),
        }
    }

    fn state_dir(&self) -> PathBuf {
        self.mux_home.join("state")
    }

    fn session_dir(&self) -> PathBuf {
        self.mux_home.join("session")
    }
}

/// The running Chief. Dropping it without `stop` leaves the threads running
/// until the daemon exits.
pub struct ChiefHandle {
    actor: Sender<Msg>,
    agent: Sender<Ctl>,
    /// The hub connection being set up or running.
    connection: Arc<Mutex<Current>>,
    threads: Vec<JoinHandle<()>>,
    ready: Arc<AtomicBool>,
}

impl ChiefHandle {
    /// True once both owners were connected and the first catch-up ran.
    pub fn is_ready(&self) -> bool {
        self.ready.load(Ordering::Acquire)
    }

    /// Stops the actor and the hub loop, closes the hub connection and
    /// releases the lock (with the actor's file).
    pub fn stop(self) {
        let _ = self.agent.send(Ctl::Stop);
        // A connect in progress fails at once instead of at its deadline.
        let connection = self.connection.lock().unwrap().stop();
        if let Some(connection) = connection {
            connection.close();
        }
        let _ = self.actor.send(Msg::Stop);
        for thread in self.threads {
            let _ = thread.join();
        }
    }
}

/// Takes the `$MUX_HOME` lock and starts the actor and the hub loop.
pub fn start_chief(
    mux: &Arc<Mux>,
    config: ChiefConfig,
    connector: Arc<dyn AgentConnector>,
) -> Result<ChiefHandle, LockError> {
    let lock = lock::take(&config.state_dir().join("host.lock"))?;
    std::fs::create_dir_all(config.session_dir())?;
    // Read after the lock: the state's only writer is the lock holder.
    let state_file = state_file::StateFile::new(config.state_dir().join("host.json"));
    let state = state_file.load(config.log.as_ref());
    let ready = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = mpsc::channel();
    let (ctl, ctl_rx) = mpsc::channel();
    let connection = Arc::new(Mutex::new(Current::default()));
    let spec = SessionSpec {
        cwd: config.session_dir().to_string_lossy().into_owned(),
        harness: config.harness.clone(),
        policy: config.policy.clone(),
    };
    let agent_thread = agent_loop::spawn(AgentLoop {
        connector,
        spec,
        sender: sender.clone(),
        ctl: ctl.clone(),
        ctl_rx,
        current: connection.clone(),
        timeout: config.request_timeout,
        backoff: Backoff { initial: config.backoff_initial, max: config.backoff_max },
        log: config.log.clone(),
    })?;
    let actor = Actor::new(mux.clone(), config, state, state_file, sender.clone(), ready.clone());
    let actor_thread = match std::thread::Builder::new()
        .name("chief-actor".into())
        .spawn(move || actor.run(receiver, lock))
    {
        Ok(thread) => thread,
        Err(error) => {
            let _ = ctl.send(Ctl::Stop);
            let _ = agent_thread.join();
            return Err(error.into());
        }
    };
    Ok(ChiefHandle {
        actor: sender,
        agent: ctl,
        connection,
        threads: vec![actor_thread, agent_thread],
        ready,
    })
}
