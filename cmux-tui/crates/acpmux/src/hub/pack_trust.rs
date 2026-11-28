//! Part of `Hub` (a child of `transfer_history.rs`). What a daemon has checked of a chat's pack
//! outlives the daemon: the trust in a chat's sealed segments (`pack_checked`: they hold the log's
//! lines at its stamp) is also kept in the pack store, as `checked.json`, so the first seal or
//! pack of a chat after a restart extends the pack from its sealed end, as every later one does,
//! instead of checking every sealed segment against the whole log again.
//!
//! Before, each daemon's first seal of a chat rendered and hashed its whole log (an 8.6 GB chat:
//! 7.2 million records through `display_logged` and `serde_json`, minutes of one core), and a
//! daemon relaunched every half hour paid it every life. Earlier builds wrote those lines to a
//! `work-*` folder first and left 3.5 to 8.4 GB there whenever a relaunch cut the pack short.
//!
//! The kept trust holds only while everything it was made from holds: the log's stamp
//! ([`Store::log_stamp`], persisted in the chat's `STAMP`; a rewrite of lines already written
//! bumps it), this daemon's build ([`crate::build_info::build`]: another build may write other
//! lines for the same records, and an unstamped build is never trusted), and the sealed
//! segments it covered, by a hash of their hashes, still the first segments of the manifest. A
//! segment sealed after it was extended from it at the same stamp. Any failed seal, a purged or
//! moved chat, and a history that arrived (`unpack_staged`) forget it, on disk too.
//!
//! The seal scratch folders in the pack store are named for their owner pid
//! (`work-<pid>-<uuid>`), and one whose owner is gone, or one named before that and older than
//! this daemon, is removed at the next seal of the chat and at hub start
//! (`transfer_out.rs` `dead_scratch`).

use super::*;
use serde::{Deserialize, Serialize};

/// The kept trust's file in a chat's pack store.
const TRUST_FILE: &str = "checked.json";

/// What `checked.json` holds.
#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeptTrust {
    /// The log's stamp the segments were checked at.
    stamp: u64,
    /// The build that checked them.
    build: String,
    /// How many of the manifest's first segments, all sealed, were checked.
    sealed: usize,
    /// SHA-256 of their `raw_hash`es, one a line.
    sealed_hash: String,
}

/// The hash of the manifest's first `n` segments, when there are that many and all are sealed.
fn sealed_hash(manifest: &pack::Manifest, n: usize) -> Option<String> {
    let first = manifest.segments.get(..n).filter(|s| !s.is_empty())?;
    if !first.iter().all(|s| s.sealed) {
        return None;
    }
    let mut joined = String::with_capacity(n * 65);
    for segment in first {
        joined.push_str(&segment.raw_hash);
        joined.push('\n');
    }
    Some(crate::sha256::sha256_hex(joined.as_bytes()))
}

/// Whether this build may keep trust across daemons: an unstamped build's lines are not known
/// to be any other unstamped build's.
fn build_kept() -> Option<&'static str> {
    Some(crate::build_info::build()).filter(|b| *b != "unstamped")
}

impl Hub {
    /// Whether chat `id`'s sealed segments in `store` are trusted at the log's stamp `stamp`:
    /// checked by this daemon, or by an earlier one of this build whose trust still holds
    /// (module docs), which this daemon then holds too.
    pub(in crate::hub) fn pack_trusted(&self, id: &str, store: &pack::Store, stamp: u64) -> bool {
        if self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).get(id) == Some(&stamp) {
            return true;
        }
        let kept = std::fs::read(store.root().join(TRUST_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<KeptTrust>(&bytes).ok());
        let Some(kept) = kept else { return false };
        if kept.stamp != stamp || build_kept() != Some(kept.build.as_str()) {
            return false;
        }
        let Ok(Some(manifest)) = pack::Manifest::load(store, id) else { return false };
        if sealed_hash(&manifest, kept.sealed).as_deref() != Some(kept.sealed_hash.as_str()) {
            return false;
        }
        self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned(), stamp);
        true
    }

    /// Records that every sealed segment of `manifest`, chat `id`'s pack in `store`, holds the
    /// log's lines at stamp `stamp`: for this daemon, and in the store for the next one.
    pub(in crate::hub) fn trust_pack(
        &self,
        id: &str,
        store: &pack::Store,
        stamp: u64,
        manifest: &pack::Manifest,
    ) {
        self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned(), stamp);
        let path = store.root().join(TRUST_FILE);
        let sealed = manifest.segments.iter().take_while(|s| s.sealed).count();
        let kept = build_kept().zip(sealed_hash(manifest, sealed)).map(|(build, sealed_hash)| {
            KeptTrust { stamp, build: build.to_owned(), sealed, sealed_hash }
        });
        let written = match kept {
            Some(kept) => serde_json::to_vec(&kept)
                .map_err(std::io::Error::other)
                .and_then(|bytes| crate::home_fs::write(&path, bytes)),
            None => crate::home_fs::remove_file(&path).or_else(not_found_is_ok),
        };
        if let Err(error) = written {
            // The next daemon checks the segments again; nothing is trusted wrongly.
            tracing::debug!(session = %id, "chat pack trust not kept: {error}");
        }
    }

    /// Forgets the trust in chat `id`'s sealed segments, this daemon's and the kept one.
    pub(in crate::hub) fn forget_pack_trust(&self, id: &str) {
        self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
        if let Some(chat) = self.store.session_dir(id) {
            let _ = crate::home_fs::remove_file(chat.join(PACK_DIR).join(TRUST_FILE));
        }
    }

    /// Removes the seal scratch a gone daemon left in chat `id`'s pack store (module docs).
    pub(in crate::hub) fn sweep_pack_work(&self, id: &str) {
        let Some(chat) = self.store.session_dir(id) else { return };
        sweep_pack_work_in(&chat.join(PACK_DIR));
    }

    /// [`Self::sweep_pack_work`] of every chat this daemon holds, at its start.
    pub(in crate::hub) fn sweep_all_pack_work(&self) {
        let ids: Vec<String> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        for id in ids {
            self.sweep_pack_work(&id);
        }
    }
}

/// A new seal scratch folder in the pack store at `root`, named for this process.
pub(in crate::hub) fn pack_work_dir(root: &Path) -> PathBuf {
    root.join(format!("work-{}-{}", std::process::id(), uuid::Uuid::now_v7().simple()))
}

/// [`Hub::sweep_pack_work`] of the pack store folder `dir`.
pub(in crate::hub) fn sweep_pack_work_in(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let changed = entry.metadata().and_then(|m| m.modified()).ok();
        if name.starts_with("work-") && super::transfer_out::dead_scratch(&name, changed) {
            tracing::info!("removing {name} in {}: seal scratch of a daemon that is gone", dir.display());
            let _ = crate::home_fs::remove_dir_all(entry.path());
        }
    }
}

fn not_found_is_ok(error: std::io::Error) -> std::io::Result<()> {
    match error.kind() {
        std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(error),
    }
}

#[cfg(test)]
#[path = "pack_trust_tests.rs"]
mod tests;
