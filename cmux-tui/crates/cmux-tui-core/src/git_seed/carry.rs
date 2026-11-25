//! `git-seed-carry-v1`: the base from the sender instead of from GitHub.
//!
//! A clone is the slow part of a seed (a blobless clone of a large repository still takes
//! minutes, and it needs a GitHub path on the machine). The sender already holds the base's
//! objects, so it packs the base commit, its tree and every blob of it (depth 1, its own
//! deltas reused) and uploads that pack beside the bundle. A fresh folder here becomes a
//! repository from it: `git init`, the pack indexed with `--strict` into the object store,
//! the base recorded as the shallow boundary, `origin` the real remote. Nothing of GitHub is
//! read; a later `git fetch` there brings what is new and keeps the boundary, and
//! `git fetch --unshallow` brings the history when someone wants it.
//!
//! Every failure (a folder with a repository already, a pack that does not index, a base
//! that is not whole in it) leaves the folder as it was and the seed clones as before; the
//! job's status notes `carried` or `carry_failed`.

use std::path::Path;
use std::time::Instant;

use super::{Failure, Seed, check_folder, clean_folder, place};

impl Seed {
    /// Whether the folder is now a shallow repository at the base from the sender's pack.
    pub(super) fn carry_in(&mut self) -> bool {
        let Some(carry) = self.carry.take() else { return false };
        if let Some(path) = &self.params.carry {
            place::delete_upload(&self.roots, path);
        }
        if self.recheck().is_err()
            || std::fs::symlink_metadata(self.folder.join(".git")).is_ok()
            || check_folder(&self.git, &self.folder, &self.params.url).is_err()
        {
            return false;
        }
        self.job.enter(super::Phase::Clone);
        let existed = self.folder.exists();
        let started = Instant::now();
        match self.unpack_carry(&carry.path) {
            Ok(()) => {
                super::super::git::count("carry", started.elapsed());
                self.job.note("carried");
                true
            }
            Err(_) => {
                clean_folder(&self.folder, existed);
                self.job.note("carry_failed");
                false
            }
        }
    }

    fn unpack_carry(&self, pack: &Path) -> Result<(), Failure> {
        let io = |what: &str, error: std::io::Error| Failure::of(format!("fatal: {what}: {error}"));
        std::fs::create_dir_all(&self.folder).map_err(|error| io("the folder", error))?;
        let folder = self.folder_str();
        let mut init = vec!["init", "--quiet"];
        if self.params.base.len() == 64 {
            init.push("--object-format=sha256");
        }
        init.extend(["--", folder.as_str()]);
        self.git.quiet(None, &self.chosen, &init)?;
        self.git(&["remote", "add", "origin", &self.params.url])?;
        // The boundary first: `index-pack --strict` checks every object it gets is connected,
        // and the base's parents are not in the pack.
        let base = &self.params.base;
        std::fs::write(self.folder.join(".git").join("shallow"), format!("{base}\n"))
            .map_err(|error| io("the shallow file", error))?;
        let packs = self.folder.join(".git").join("objects").join("pack");
        let incoming = packs.join("tmp_carry.pack");
        // The copy is this daemon's own; a rename when it is on the same filesystem.
        if std::fs::rename(pack, &incoming).is_err() {
            std::fs::copy(pack, &incoming).map_err(|error| io("the carry pack", error))?;
        }
        let incoming_str = incoming.display().to_string();
        // `--strict`: every object is checked as `transfer.fsckObjects` checks a fetch's.
        let name = self.git(&["index-pack", "--strict", &incoming_str])?;
        let name = String::from_utf8_lossy(&name).trim().to_owned();
        let hex = name.bytes().all(|byte| byte.is_ascii_hexdigit());
        if !hex || !(name.len() == 40 || name.len() == 64) {
            return Err(Failure::of(format!("fatal: index-pack answered {name:?}")));
        }
        // The reverse index, when this git writes one (`pack.writeReverseIndex`), goes along.
        for extension in ["rev", "idx", "pack"] {
            let from = packs.join(format!("tmp_carry.{extension}"));
            let to = packs.join(format!("pack-{name}.{extension}"));
            match std::fs::rename(&from, &to) {
                Err(error)
                    if extension == "rev" && error.kind() == std::io::ErrorKind::NotFound => {}
                done => done.map_err(|error| io("the carry pack", error))?,
            }
        }
        // The base and every object of its tree are here (a blob rev-list only names is
        // checked too): a missing one would fail the checkout after the clone was given up.
        let missing = self.git(&["rev-list", "--objects", "--no-walk", "--missing=print", base])?;
        if let Some(line) = missing.split(|byte| *byte == b'\n').find(|line| line.starts_with(b"?"))
        {
            return Err(Failure::of(format!(
                "fatal: the carry pack lacks {}",
                String::from_utf8_lossy(line)
            )));
        }
        if !self.has_commit(base) {
            return Err(Failure::of("fatal: the carry pack lacks the base commit"));
        }
        Ok(())
    }
}
