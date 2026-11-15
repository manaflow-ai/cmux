//! The folders a push made itself. A folder that was not on the machine until this push's
//! `fs.mkdir` made it holds nothing of the machine's, so for it and everything below it the
//! push asks nothing first: no `fs.stat` of each folder on the way (is it a symlink?), no
//! `fs.list` of the folder (what is in the way of each file?) and no `fs.stat` before each
//! `fs.mkdir` below it (is it there yet?). Each of those was one round trip of the link, one
//! request at a time, for every new folder: five for a new folder below an existing one
//! (`through_link`, the listing, `mkdir_all`'s two `is_dir` and the `fs.mkdir`), about 500 ms
//! a folder over a Cloud machine's link. A chat's copy (`cmux link start-chat copy`) always
//! goes to a new folder, so all of its folders are made this way at one `fs.mkdir` each, and
//! those go [`MKDIR_BATCH`] to a round trip once the push knows every folder ([`Fresh::flush`]).
//!
//! Every write still goes as before: a no-follow write is refused by the machine itself when
//! a symlink is on its path, and a machine without no-follow writes has each file's folders
//! checked again on the connection that writes it (`write_checked`).

use std::collections::BTreeSet;

use serde_json::json;

use super::remote::{self, Remote};

pub(super) struct Fresh {
    root: String,
    /// Folders this push made.
    made: BTreeSet<String>,
    /// Folders known to be there already (the root, and each `mkdir_all` answered).
    there: BTreeSet<String>,
    /// The `fs.mkdir`s of made folders not sent yet, `(parent, name)`, parents first
    /// ([`Fresh::flush`]).
    pending: Vec<(String, String)>,
}

/// Most `fs.mkdir`s one batch sends.
const MKDIR_BATCH: usize = 256;

impl Fresh {
    /// Makes `root` (and what is missing above it) and starts the record: the root is this
    /// push's own when it was not there before.
    pub(super) fn make_root(remote: &mut Remote, root: &str) -> anyhow::Result<Self> {
        let there = remote.kind(root)?.is_some();
        remote.mkdir_all(root)?;
        let mut fresh = Self {
            root: root.to_owned(),
            made: BTreeSet::new(),
            there: BTreeSet::new(),
            pending: Vec::new(),
        };
        if there {
            fresh.there.insert(root.to_owned());
        } else {
            fresh.made.insert(root.to_owned());
        }
        Ok(fresh)
    }

    /// Whether `folder` is one this push made or is below one (made yet or not): nothing in
    /// it is the machine's.
    pub(super) fn covers(&self, folder: &str) -> bool {
        let mut at = folder;
        loop {
            if self.made.contains(at) {
                return true;
            }
            if at == self.root || !at.starts_with(&self.root) {
                return false;
            }
            match remote::split(at) {
                Ok((parent, _)) if parent.len() < at.len() => at = parent,
                _ => return false,
            }
        }
    }

    /// Makes `folder` and the folders above it that are missing: below a folder this push made
    /// with one `fs.mkdir` each and nothing asked first; elsewhere as [`Remote::mkdir_all`].
    pub(super) fn make(&mut self, remote: &mut Remote, folder: &str) -> anyhow::Result<()> {
        if self.made.contains(folder) || self.there.contains(folder) {
            return Ok(());
        }
        let (parent, name) = remote::split(folder)?;
        let below = parent.len() < folder.len() && folder.starts_with(&self.root);
        // Outside a made folder it is asked about first: what is there stays as `mkdir_all`
        // answers it (a folder is used, anything else refused).
        if !below || (!self.covers(parent) && remote.kind(folder)?.is_some()) {
            remote.mkdir_all(folder)?;
            self.there.insert(folder.to_owned());
            return Ok(());
        }
        self.make(remote, parent)?;
        if below && self.covers(parent) {
            // Sent with the others in [`Fresh::flush`], after its parent's.
            self.pending.push((parent.to_owned(), name.to_owned()));
            self.made.insert(folder.to_owned());
            return Ok(());
        }
        match remote.call("fs.mkdir", json!({ "path": parent, "name": name })) {
            Ok(_) => {
                self.made.insert(folder.to_owned());
            }
            // Something came there since: as before, and not this push's own.
            Err(error) if remote::refusal_code(&error) == Some("fs.exists") => {
                remote.mkdir_all(folder)?;
                self.there.insert(folder.to_owned());
            }
            Err(error) => return Err(error),
        }
        Ok(())
    }

    /// Makes the made folders not made yet, [`MKDIR_BATCH`] requests to a round trip: one
    /// connection runs them in order, so a folder's parent is made before it. One that is
    /// there already is taken as [`Remote::mkdir_all`] takes it (a folder is used, anything
    /// else refused).
    pub(super) fn flush(&mut self, remote: &mut Remote) -> anyhow::Result<()> {
        let pending = std::mem::take(&mut self.pending);
        for chunk in pending.chunks(MKDIR_BATCH) {
            let requests = chunk
                .iter()
                .map(|(parent, name)| ("fs.mkdir", json!({ "path": parent, "name": name })))
                .collect();
            let called = remote.call_batch(requests);
            if let Some(error) = called.failed {
                return Err(error);
            }
            for ((parent, name), answer) in chunk.iter().zip(called.answers) {
                match answer {
                    Some(Ok(_)) => {}
                    Some(Err(error)) if remote::refusal_code(&error) == Some("fs.exists") => {
                        remote.mkdir_all(&format!("{parent}/{name}"))?;
                    }
                    Some(Err(error)) => return Err(error),
                    None => anyhow::bail!("the machine did not answer making {parent}/{name}"),
                }
            }
        }
        Ok(())
    }
}
