//! The machine each recent `cloud.startChat` send ran on, newest last, at
//! most [`LIMIT`]: a retry of a send names it, so the retry's tab key (which
//! only that machine's daemon knows) gets back the tab its first try opened,
//! never a second chat elsewhere. With it, where the send's copy goes on that
//! machine and, once it finished, the chat's folder there: a retry opens its
//! chat there without copying again.
//!
//! Each send is kept under the account it began in ([`Send`]): a team
//! switch keeps the person signed in, so a send of the previous team never
//! names this team's machine, and switching back finds it again.
//!
//! Apart from the sends, the machine each recent Mac workspace that sent to
//! Cloud picked, under its account too: a workspace keeps its machine however
//! many sends ran since. The file can hold many workspaces on one machine;
//! that a machine serves one workspace for now is the pick's policy
//! ([`super::pick`]), not this file's shape. The newest [`WORKSPACE_LIMIT`]
//! workspaces are remembered; that bounds this file, not how many machines or
//! workspaces a person has (an older workspace's next send gets a new machine).
//!
//! Kept in `<state>/cloud-start-chat/destinations.json` (0600, its folder
//! 0700), read and written under an exclusive lock on a sibling `.lock` file
//! (released when the process exits, also when it is killed)
//! so two sends at once never lose each other's pins, and written to a
//! temporary name and renamed.

use std::collections::BTreeSet;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use serde::{Deserialize, Serialize};

/// How many sends are kept.
pub(crate) const LIMIT: usize = 64;

/// How many workspaces' machines are kept.
pub(crate) const WORKSPACE_LIMIT: usize = 256;

/// A send in the account it began in: its key and the account (the user and
/// the team, as the App spells them), both lowercased.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Send {
    key: String,
    account: String,
}

impl Send {
    pub(crate) fn new(key: &str, account: &str) -> Self {
        Self { key: key.to_lowercase(), account: account.to_lowercase() }
    }

    pub(crate) fn key(&self) -> &str {
        &self.key
    }

    pub(crate) fn account(&self) -> &str {
        &self.account
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Entry {
    key: String,
    #[serde(default)]
    account: String,
    machine_id: String,
    /// The folder under the machine's work root this send's copy goes to,
    /// kept before anything is copied (see [`Ledger::start_copy`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    place: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    copied_chat: Option<String>,
}

impl Entry {
    fn is(&self, send: &Send) -> bool {
        self.key == send.key && self.account == send.account
    }
}

/// One send as the App kept it before cmux-tui did: its key is the send's
/// key and account (`KEY@USER/TEAM`), and `place` the folder of its copy.
#[derive(Clone, Debug, Deserialize)]
pub(crate) struct AppEntry {
    pub(crate) key: String,
    #[serde(rename = "machineID")]
    pub(crate) machine_id: String,
    #[serde(default, rename = "copiedChat")]
    pub(crate) copied_chat: Option<String>,
    #[serde(default)]
    pub(crate) place: Option<String>,
}

/// The machine a Mac workspace picked, in the account it sent in. The file allows other
/// workspaces on it too; the pick gives each workspace its own for now.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Binding {
    workspace: String,
    account: String,
    machine_id: String,
}

/// The file: the sends, then the workspaces. An older ledger is the sends' list alone.
#[derive(Serialize, Deserialize)]
struct File {
    sends: Vec<Entry>,
    #[serde(default)]
    workspaces: Vec<Binding>,
}

/// The pins, in memory.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Ledger {
    entries: Vec<Entry>,
    workspaces: Vec<Binding>,
}

impl Ledger {
    /// The machine `send` ran on, if it ran.
    pub(crate) fn machine(&self, send: &Send) -> Option<String> {
        self.entry(send).map(|entry| entry.machine_id.clone())
    }

    /// Every machine a kept send of the account `account` ran on, or one of
    /// its workspaces picked: what counts as that account's own machine when the
    /// server names no creator. Another user's sends on this Mac, or another
    /// team's, never do.
    pub(crate) fn machines_of(&self, account: &str) -> BTreeSet<String> {
        let account = account.to_lowercase();
        self.entries
            .iter()
            .filter(|entry| entry.account == account)
            .map(|entry| entry.machine_id.clone())
            .chain(self.workspace_machines(&account))
            .collect()
    }

    /// The machine the Mac workspace `workspace` picked in `account`, once a send from it ran on one.
    pub(crate) fn workspace_machine(&self, workspace: &str, account: &str) -> Option<String> {
        let account = account.to_lowercase();
        self.workspaces
            .iter()
            .find(|binding| binding.workspace == workspace && binding.account == account)
            .map(|binding| binding.machine_id.clone())
    }

    /// Whether a Mac workspace other than `workspace` picked `machine` in `account`.
    pub(crate) fn held_by_another(&self, machine: &str, workspace: &str, account: &str) -> bool {
        let account = account.to_lowercase();
        self.workspaces.iter().any(|binding| {
            binding.machine_id == machine
                && binding.account == account
                && binding.workspace != workspace
        })
    }

    /// The machines some workspace in `account` picked.
    fn workspace_machines(&self, account: &str) -> BTreeSet<String> {
        let account = account.to_lowercase();
        self.workspaces
            .iter()
            .filter(|binding| binding.account == account)
            .map(|binding| binding.machine_id.clone())
            .collect()
    }

    /// `workspace` picks `machine` in `account` from now on.
    pub(crate) fn bind(&mut self, workspace: &str, account: &str, machine: &str) {
        self.unbind(workspace, account);
        self.workspaces.push(Binding {
            workspace: workspace.to_string(),
            account: account.to_lowercase(),
            machine_id: machine.to_string(),
        });
        let over = self.workspaces.len().saturating_sub(WORKSPACE_LIMIT);
        self.workspaces.drain(..over);
    }

    /// Drops the workspace `workspace`'s machine in `account` (gone, or no longer the person's).
    pub(crate) fn unbind(&mut self, workspace: &str, account: &str) {
        let account = account.to_lowercase();
        self.workspaces
            .retain(|binding| binding.workspace != workspace || binding.account != account);
    }

    /// Pins `send` to `machine` (before anything runs there). A pin to the
    /// same machine keeps its copy's place and finished copy.
    pub(crate) fn record(&mut self, machine: &str, send: &Send) {
        let same = self.entry(send).filter(|entry| entry.machine_id == machine);
        let (place, copied_chat) =
            same.map_or((None, None), |entry| (entry.place.clone(), entry.copied_chat.clone()));
        self.put(Entry {
            key: send.key.clone(),
            account: send.account.clone(),
            machine_id: machine.to_string(),
            place,
            copied_chat,
        });
    }

    /// The chat's folder on `machine` when `send`'s copy finished there.
    pub(crate) fn copied_chat(&self, send: &Send, machine: &str) -> Option<String> {
        self.entry(send)
            .filter(|entry| entry.machine_id == machine)
            .and_then(|entry| entry.copied_chat.clone())
    }

    /// The folder of `send`'s copy to `machine` that started and did not
    /// finish: a retry resumes it while no live copy holds it
    /// ([`super::StartCopy::run`]).
    pub(crate) fn copy_place(&self, send: &Send, machine: &str) -> Option<String> {
        self.entry(send)
            .filter(|entry| entry.machine_id == machine && entry.copied_chat.is_none())
            .and_then(|entry| entry.place.clone())
    }

    /// `send`'s copy to `machine` starts now, into `place`. Kept before
    /// anything is copied: a retry of a copy that does not finish resumes
    /// it there, unless a live copy still holds it ([`super::Lease`]).
    pub(crate) fn start_copy(&mut self, send: &Send, machine: &str, place: &str) {
        self.put(Entry {
            key: send.key.clone(),
            account: send.account.clone(),
            machine_id: machine.to_string(),
            place: Some(place.to_string()),
            copied_chat: None,
        });
    }

    /// `send`'s copy into `place` finished on `machine`, its chat's folder there `chat`.
    pub(crate) fn record_copy(&mut self, chat: &str, send: &Send, machine: &str, place: &str) {
        self.put(Entry {
            key: send.key.clone(),
            account: send.account.clone(),
            machine_id: machine.to_string(),
            place: Some(place.to_string()),
            copied_chat: Some(chat.to_string()),
        });
    }

    /// Takes in the sends the App kept before cmux-tui did (its user defaults'
    /// `cmux.cloud.startChatDestinations`, oldest first): their pins, copies
    /// and what made a creatorless machine the account's own carry over. A
    /// send this ledger already has keeps its own; one kept under no account
    /// (from before sends were kept per account) is left out, since it cannot
    /// say whose it is. The newest [`LIMIT`] are kept, this ledger's last.
    pub(crate) fn import(&mut self, kept: &[AppEntry]) -> usize {
        let mut imported: Vec<Entry> = Vec::new();
        for old in kept {
            let Some((key, account)) = old.key.split_once('@') else { continue };
            let send = Send::new(key, account);
            if self.entry(&send).is_some() {
                continue;
            }
            imported.retain(|entry| !entry.is(&send));
            imported.push(Entry {
                key: send.key,
                account: send.account,
                machine_id: old.machine_id.clone(),
                place: old.place.clone(),
                copied_chat: old.copied_chat.clone(),
            });
        }
        let count = imported.len();
        imported.append(&mut self.entries);
        let over = imported.len().saturating_sub(LIMIT);
        imported.drain(..over);
        self.entries = imported;
        count
    }

    /// Drops `send`'s pin (its machine is gone).
    pub(crate) fn forget(&mut self, send: &Send) {
        self.entries.retain(|entry| !entry.is(send));
    }

    fn entry(&self, send: &Send) -> Option<&Entry> {
        self.entries.iter().rev().find(|entry| entry.is(send))
    }

    fn put(&mut self, entry: Entry) {
        self.entries.retain(|kept| kept.key != entry.key || kept.account != entry.account);
        self.entries.push(entry);
        let over = self.entries.len().saturating_sub(LIMIT);
        self.entries.drain(..over);
    }

    /// Reads the ledger at `path`, runs `change` on it and writes it back
    /// when it changed, under the ledger's lock. A missing ledger reads as
    /// empty. One that cannot be read refuses (see [`Self::read`]): it never
    /// reads as empty, which would make a retry pick and copy afresh.
    pub(crate) fn update<T>(
        path: &Path,
        change: impl FnOnce(&mut Ledger) -> T,
    ) -> anyhow::Result<T> {
        let dir = path.parent().context("the ledger has no folder")?;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .with_context(|| format!("cannot make {}", dir.display()))?;
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path.with_extension("lock"))
            .with_context(|| format!("cannot open the lock of {}", path.display()))?;
        lock.lock().context("cannot lock the ledger")?;
        let mut ledger = Self::read(path)?;
        let before = ledger.clone();
        let value = change(&mut ledger);
        if ledger != before {
            ledger.write(path)?;
        }
        drop(lock);
        Ok(value)
    }

    /// The ledger at `path`; empty when there is none. A read that fails
    /// refuses and leaves the file as it is (it may only be busy). A file
    /// that is not a ledger (cut short, damaged, or another version's) also
    /// refuses: it is moved aside with its bytes as they are ([`unreadable_path`]),
    /// so the person can still start chats, and this send is not started.
    fn read(path: &Path) -> anyhow::Result<Self> {
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self::default());
            }
            Err(error) => {
                return Err(error).with_context(|| format!("cannot read {}", path.display()));
            }
        };
        let file = serde_json::from_slice::<File>(&bytes).or_else(|error| {
            serde_json::from_slice::<Vec<Entry>>(&bytes)
                .map(|sends| File { sends, workspaces: Vec::new() })
                .map_err(|_| error)
        });
        match file {
            Ok(file) => Ok(Self { entries: file.sends, workspaces: file.workspaces }),
            Err(error) => {
                let aside = unreadable_path(path);
                std::fs::rename(path, &aside).with_context(|| {
                    format!(
                        "{} is not a ledger ({error}) and cannot be moved aside",
                        path.display()
                    )
                })?;
                anyhow::bail!(
                    "{} is not a ledger ({error}); it is kept as {}",
                    path.display(),
                    aside.display()
                )
            }
        }
    }

    fn write(&self, path: &Path) -> anyhow::Result<()> {
        let part = path.with_extension(format!("{}.part", std::process::id()));
        let _ = std::fs::remove_file(&part);
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&part)
            .with_context(|| format!("cannot write {}", part.display()))?;
        let ledger = File { sends: self.entries.clone(), workspaces: self.workspaces.clone() };
        file.write_all(&serde_json::to_vec(&ledger)?)?;
        file.sync_all()?;
        std::fs::rename(&part, path).with_context(|| format!("cannot write {}", path.display()))
    }
}

/// Where an unreadable ledger at `path` is kept: beside it, named for when it was moved.
pub(crate) fn unreadable_path(path: &Path) -> PathBuf {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    path.with_extension(format!("unreadable-{now}.json"))
}

/// Where this Mac keeps the ledger; None when it has no state folder.
pub(crate) fn path() -> Option<PathBuf> {
    Some(
        cmux_tui_core::platform::workspace_state_dir()?
            .join("cloud-start-chat")
            .join("destinations.json"),
    )
}
