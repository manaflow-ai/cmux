//! Live launch proofs and operation serialization. No proof is written to the run record.

use super::{RunRecord, Store};
use anyhow::{Result, ensure};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub const RUNNER_TOKEN_ENV: &str = "CMUX_WORKFLOW_RUNNER_TOKEN";

pub struct Service {
    root: Option<PathBuf>,
    proofs: Mutex<BTreeMap<(String, u64), String>>,
    gates: Mutex<BTreeMap<String, Arc<tokio::sync::Mutex<()>>>>,
    runners: Mutex<BTreeMap<(String, u64), Runner>>,
}

struct Runner {
    stop: tokio::sync::oneshot::Sender<()>,
    done: tokio::sync::oneshot::Receiver<()>,
}

impl Default for Service {
    fn default() -> Self {
        Self {
            root: None,
            proofs: Mutex::new(BTreeMap::new()),
            gates: Mutex::new(BTreeMap::new()),
            runners: Mutex::new(BTreeMap::new()),
        }
    }
}

impl Service {
    pub fn with_root(root: PathBuf) -> Self {
        Self { root: Some(root), ..Self::default() }
    }

    pub fn store(&self) -> Store {
        Store::new(self.root.clone().unwrap_or_else(|| crate::config::home().join("workflows")))
    }

    /// Hold across activity registration + dispatch, or pause + child cancellation. This makes
    /// the pause fence order a dispatch before its cancellation or a refusal after the fence.
    pub fn gate(&self, run_id: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.gates
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(run_id.to_owned())
            .or_default()
            .clone()
    }

    pub fn issue_runner(&self, run: &RunRecord) -> Result<Option<String>> {
        let mut proofs = self.proofs.lock().unwrap_or_else(|e| e.into_inner());
        let key = (run.id.clone(), run.generation);
        if proofs.contains_key(&key) {
            return Ok(None);
        }
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes)
            .map_err(|error| anyhow::anyhow!("create workflow runner proof: {error}"))?;
        let token = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
        proofs.retain(|(id, _), _| id != &run.id);
        proofs.insert(key, token.clone());
        Ok(Some(token))
    }

    pub fn retire_runner(&self, run_id: &str, generation: u64) {
        self.proofs
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&(run_id.to_owned(), generation));
        self.runners
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&(run_id.to_owned(), generation));
    }

    pub fn track_runner(
        &self,
        run_id: &str,
        generation: u64,
    ) -> (tokio::sync::oneshot::Receiver<()>, tokio::sync::oneshot::Sender<()>) {
        let (stop, receive) = tokio::sync::oneshot::channel();
        let (finished, done) = tokio::sync::oneshot::channel();
        self.runners
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert((run_id.to_owned(), generation), Runner { stop, done });
        (receive, finished)
    }

    /// The new runner cannot take its journal lock until the recorded old process has exited.
    /// Only the child handle from this launch receives a stop; never a PID lookup.
    pub async fn stop_runner(&self, run_id: &str) {
        self.proofs.lock().unwrap_or_else(|e| e.into_inner()).retain(|(id, _), _| id != run_id);
        let stopped = {
            let mut runners = self.runners.lock().unwrap_or_else(|e| e.into_inner());
            let keys = runners.keys().filter(|(id, _)| id == run_id).cloned().collect::<Vec<_>>();
            keys.into_iter().filter_map(|key| runners.remove(&key)).collect::<Vec<_>>()
        };
        for Runner { stop, done } in stopped {
            let _ = stop.send(());
            let _ = done.await;
        }
    }

    pub fn authorize_runner(
        &self,
        run_id: &str,
        generation: u64,
        token: &str,
    ) -> Result<RunRecord> {
        let valid = self
            .proofs
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&(run_id.to_owned(), generation))
            .is_some_and(|expected| cmux_local_auth::tokens_match(token, expected));
        ensure!(valid, "workflow runner proof does not match this daemon launch");
        let run = self.store().get(run_id)?;
        self.store().authorize(run_id, generation, &run.owner_session_id)
    }
}
