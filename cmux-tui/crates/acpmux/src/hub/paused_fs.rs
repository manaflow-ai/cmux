//! Part of `Hub`; see `hub/mod.rs`. The ACP file methods of a chat whose machine is paused
//! (M20, `writeJournal.enabled`, off by default): `fs/read_text_file` and `fs/write_text_file`
//! are answered from the machine's replica and write journal (`crate::write_journal::paused`)
//! with no resume. A read the replica cannot answer resumes the machine first
//! ([`Hub::wake_paused_machine`], also the barrier anything that runs a command there calls).
//! Conflicts the flush found are the agent's next file call's answer: that call is not run, and
//! its error says what did not apply and to run it again.

use super::*;
use crate::write_journal::flush::FlushReport;
use crate::write_journal::paused::{MachineResume, PausedFs, Routed};
use crate::write_journal::replica::ReadOutcome;
use crate::write_journal::seed::{SeedBounds, SeedReport};
use crate::write_journal::{FileJournalStore, JournalStore, MemoryJournalStore};

/// The paused machines' state when `writeJournal.enabled`: the journals beside the daemon's
/// other state in `home` (`write-journal/`), or in memory when the store keeps nothing.
pub(super) fn open(config: &Config, home: Option<&Path>) -> Option<Arc<PausedFs>> {
    if !config.write_journal.enabled {
        return None;
    }
    let (store, replicas): (Arc<dyn JournalStore>, PathBuf) = match home {
        Some(home) => (
            Arc::new(FileJournalStore::new(home.join("write-journal"))),
            home.join("write-journal").join("replicas"),
        ),
        None => (
            Arc::new(MemoryJournalStore::default()),
            std::env::temp_dir().join(format!(
                "acpmux-replicas-{}-{}",
                std::process::id(),
                uuid::Uuid::now_v7()
            )),
        ),
    };
    Some(Arc::new(PausedFs::new(store, replicas, SeedBounds::default())))
}

fn io_rpc(what: &str, e: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("{what}: {e}"))
}

impl Hub {
    /// `machine`, whose working tree is `root`, is paused: seed its replica, so its chats' file
    /// reads and writes are answered without resuming it. `resumer` resumes it when only the
    /// machine can answer. An error when `writeJournal.enabled` is off.
    pub async fn pause_machine(
        &self,
        machine: &str,
        root: &Path,
        resumer: Arc<dyn MachineResume>,
    ) -> std::io::Result<SeedReport> {
        let Some(fs) = self.paused_fs.clone() else {
            return Err(std::io::Error::other("writeJournal.enabled is off"));
        };
        let (machine, root, resumes) =
            (machine.to_owned(), root.to_path_buf(), self.resume_count());
        tokio::task::spawn_blocking(move || fs.pause(&machine, &root, resumer, resumes))
            .await
            .map_err(std::io::Error::other)?
    }

    /// `machine` runs again: apply its journal there. `None` when it was not paused here.
    pub async fn machine_resumed_fs(&self, machine: &str) -> std::io::Result<Option<FlushReport>> {
        let Some(fs) = self.paused_fs.clone() else { return Ok(None) };
        let machine = machine.to_owned();
        tokio::task::spawn_blocking(move || fs.resumed(&machine))
            .await
            .map_err(std::io::Error::other)?
    }

    /// The exec barrier: resume a paused `machine` and apply its journal before anything runs
    /// there. Nothing when it is not paused here.
    pub async fn wake_paused_machine(&self, machine: &str) -> std::io::Result<()> {
        let Some(resumer) = self.paused_fs.as_ref().and_then(|fs| fs.resumer(machine)) else {
            return Ok(());
        };
        resumer.resume(machine).await?;
        self.machine_resumed_fs(machine).await.map(drop)
    }

    /// The paused-machine state, when `writeJournal.enabled`.
    pub fn paused_fs(&self) -> Option<&Arc<PausedFs>> {
        self.paused_fs.as_ref()
    }

    fn fs_machine(&self, session: &Session) -> Option<(Arc<PausedFs>, String)> {
        let fs = self.paused_fs.as_ref()?;
        let cwd = session.meta().cwd;
        let machine = fs.machine_of(&cwd).or_else(|| fs.machine_of(&cwd.canonicalize().ok()?))?;
        Some((fs.clone(), machine))
    }

    /// Conflicts the last flush left for this chat's machine: the call is answered with them.
    pub(super) fn journal_notices(&self, session: &Session) -> Result<(), RpcError> {
        let Some((fs, machine)) = self.fs_machine(session) else { return Ok(()) };
        let notices = fs.take_notices(&machine);
        if notices.is_empty() {
            return Ok(());
        }
        Err(RpcError::new(
            -32000,
            format!(
                "Edits you made while the machine was paused did not all apply. {} This call was \
                 not run; run it again.",
                notices.join(" ")
            ),
        ))
    }

    /// A read of `path` answered for a paused machine: `None` when the machine answers (it runs,
    /// or it was resumed just now because only it could).
    pub(super) async fn journal_read(
        &self,
        session: &Session,
        path: &Path,
    ) -> Result<Option<String>, RpcError> {
        let Some((fs, machine)) = self.fs_machine(session) else { return Ok(None) };
        let (m, p, resumes) = (machine.clone(), path.to_path_buf(), self.resume_count());
        let routed = tokio::task::spawn_blocking(move || fs.read(&m, &p, resumes))
            .await
            .map_err(|e| io_rpc("read", e))?
            .map_err(|e| io_rpc(&format!("read {}", path.display()), e))?;
        match routed {
            Routed::NotPaused => Ok(None),
            Routed::Answered(ReadOutcome::Text(text)) => Ok(Some(text)),
            Routed::Answered(ReadOutcome::NotFound) => Err(io_rpc(
                &format!("read {}", path.display()),
                std::io::Error::from(std::io::ErrorKind::NotFound),
            )),
            Routed::Answered(ReadOutcome::NeedsMachine(_)) | Routed::NeedsMachine(_) => {
                self.wake_machine_for(session, &machine).await.map(|()| None)
            }
        }
    }

    /// A write answered for a paused machine: true when journaled.
    pub(super) async fn journal_write(
        &self,
        session: &Session,
        path: &Path,
        content: &str,
    ) -> Result<bool, RpcError> {
        let Some((fs, machine)) = self.fs_machine(session) else { return Ok(false) };
        let (m, p, c) = (machine.clone(), path.to_path_buf(), content.to_owned());
        let (resumes, at) = (self.resume_count(), crate::store::now_ms());
        let routed = tokio::task::spawn_blocking(move || fs.write(&m, &p, &c, resumes, at))
            .await
            .map_err(|e| io_rpc("write", e))?
            .map_err(|e| io_rpc(&format!("write {}", path.display()), e))?;
        match routed {
            Routed::NotPaused => Ok(false),
            Routed::Answered(_) => Ok(true),
            Routed::NeedsMachine(_) => {
                self.wake_machine_for(session, &machine).await.map(|()| false)
            }
        }
    }

    /// Resumes `machine` for a call only it can answer; a conflict of that flush answers the call.
    async fn wake_machine_for(&self, session: &Session, machine: &str) -> Result<(), RpcError> {
        self.wake_paused_machine(machine).await.map_err(|e| io_rpc("resume the machine", e))?;
        self.journal_notices(session)
    }
}
