//! The folders a push made itself. A folder that was not on the machine until this push's
//! `fs.mkdir` made it holds nothing of the machine's, so for it and everything below it the
//! push asks nothing first: no `fs.stat` of each folder on the way (is it a symlink?), no
//! `fs.list` of the folder (what is in the way of each file?) and no `fs.stat` before each
//! `fs.mkdir` below it (is it there yet?). Each of those was one round trip of the link, one
//! request at a time, for every new folder: five for a new folder below an existing one
//! (`through_link`, the listing, `mkdir_all`'s two `is_dir` and the `fs.mkdir`), about 500 ms
//! a folder over a Cloud machine's link. A chat's copy (`cmux link start-chat copy`) always
//! goes to a new folder, so all of its folders are made this way at one `fs.mkdir` each.
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
}

impl Fresh {
    /// Makes `root` (and what is missing above it) and starts the record: the root is this
    /// push's own when it was not there before.
    pub(super) fn make_root(remote: &mut Remote, root: &str) -> anyhow::Result<Self> {
        let there = remote.kind(root)?.is_some();
        remote.mkdir_all(root)?;
        let mut fresh =
            Self { root: root.to_owned(), made: BTreeSet::new(), there: BTreeSet::new() };
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
        if !(below && self.covers(parent)) && (!below || remote.kind(folder)?.is_some()) {
            remote.mkdir_all(folder)?;
            self.there.insert(folder.to_owned());
            return Ok(());
        }
        self.make(remote, parent)?;
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
}
