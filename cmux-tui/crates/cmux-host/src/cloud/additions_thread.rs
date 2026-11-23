//! The I/O half of `additions.rs`: the machine's package names, read from disk (no process is
//! spawned), and the thread that lists and sends them off the poll loop.
//!
//! The names are the ones `userAdditionsCommand()` in `web/scripts/cmux-vm-image/layers.ts`
//! prints: apt (the dpkg status database), npm globals (the global `node_modules` beside the
//! `npm` the image runs), bun globals, uv tools, pipx venvs and `~/.cargo/bin`, under the work
//! user's home. A scope folder (`@scope`) counts as its packages, as `npm ls` names them. A path
//! under the home that is a symlink is not followed: the work user owns that home, and this
//! thread runs as root.
//!
//! The thread waits for an idle edge ([`Additions::collect`]); several queued while it works
//! count as one. It ends when the worker drops its [`Additions`] (a rebind replaces it).

use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::mpsc::{self, Receiver, SyncSender};

use super::additions::{IMAGE_PACKAGES_FILE, Outcome, SENT_FILE, collect, dpkg_names};
use super::client::{CloudClient, Http, Store};
use crate::config::Paths;

/// The dpkg status database (`dpkg-query -W` reads it).
pub const DPKG_STATUS_FILE: &str = "/var/lib/dpkg/status";
/// Where the image's `npm` may be: the store profile first, then the system's.
const NPM_BINS: [&str; 3] = ["/opt/cmux/current/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"];

/// Wakes the thread at an idle edge; dropping it ends the thread.
pub struct Additions {
    wake: SyncSender<()>,
}

impl Additions {
    pub fn spawn<H: Http + Send + 'static, S: Store + Send + 'static>(
        mut client: CloudClient<H>,
        paths: Paths,
        mut store: S,
        now_wall_ms: fn() -> u64,
        log: fn(&str),
    ) -> std::io::Result<Additions> {
        let (wake, woken) = mpsc::sync_channel(1);
        std::thread::Builder::new().name("cmux-host-additions".to_owned()).spawn(move || {
            let home = crate::daemon_spec::WORK_HOME;
            run(&woken, |_| {
                let outcome = collect_once(&paths, home, &mut store, |body| {
                    client.install_additions(body, now_wall_ms())
                });
                log(&note(&outcome));
            });
        })?;
        Ok(Additions { wake })
    }

    /// The machine went idle with the person's choice on: list and send once, off this thread.
    pub fn collect(&self) {
        // Full: a pass is already due. Disconnected: the thread ended.
        let _ = self.wake.try_send(());
    }
}

/// One pass per wake; wakes queued meanwhile count as one.
fn run(woken: &Receiver<()>, mut pass: impl FnMut(())) {
    while woken.recv().is_ok() {
        while woken.try_recv().is_ok() {}
        pass(());
    }
}

/// The journal line (counts only, never a name).
pub fn note(outcome: &Outcome) -> String {
    match outcome {
        Outcome::NoBaseline => "additions: no image baseline; nothing sent".to_owned(),
        Outcome::Unchanged => "additions: unchanged since the last list stored".to_owned(),
        Outcome::Stored { names, .. } => format!("additions: {names} names stored"),
        Outcome::NotShared => "additions: usage sharing is off; nothing stored".to_owned(),
        Outcome::Failed(why) => format!("additions: not stored ({why}); the next idle retries"),
    }
}

/// One collection on `paths`' root: the baseline, the names, the last stored hash, the send, and
/// the new hash kept on a store.
pub fn collect_once(
    paths: &Paths,
    home: &str,
    store: &mut dyn Store,
    post: impl FnOnce(&serde_json::Value) -> super::sender::Answer,
) -> Outcome {
    let baseline = fs::read_to_string(paths.at(IMAGE_PACKAGES_FILE)).ok();
    let last = store.read(SENT_FILE);
    let outcome = collect(baseline.as_deref(), || names(paths, home), last.as_deref(), post);
    if let Outcome::Stored { hash, .. } = &outcome
        && let Err(e) = store.write(SENT_FILE, &format!("{hash}\n"), 0o600)
    {
        return Outcome::Failed(format!("stored, but the hash was not kept: {e}"));
    }
    outcome
}

/// Every `<kind> <name>` the machine has now (unsorted; `additions` sorts and filters).
pub fn names(paths: &Paths, home: &str) -> Vec<String> {
    let mut out =
        fs::read_to_string(paths.at(DPKG_STATUS_FILE)).map(|s| dpkg_names(&s)).unwrap_or_default();
    if let Some(root) = npm_global_root(paths) {
        out.extend(packages(&root).into_iter().map(|n| format!("npm {n}")));
    }
    let under = |rel: &str| under_home(paths, home, rel);
    if let Some(dir) = under(".bun/install/global/node_modules") {
        out.extend(packages(&dir).into_iter().map(|n| format!("bun {n}")));
    }
    for (kind, rel) in
        [("uv", ".local/share/uv/tools"), ("pipx", ".local/pipx/venvs"), ("cargo", ".cargo/bin")]
    {
        if let Some(dir) = under(rel) {
            out.extend(entries(&dir).into_iter().map(|n| format!("{kind} {n}")));
        }
    }
    out
}

/// The global `node_modules` of the first `npm` found: its real path is
/// `<prefix>/lib/node_modules/npm/bin/npm-cli.js`, so the folder is its `node_modules` ancestor.
fn npm_global_root(paths: &Paths) -> Option<PathBuf> {
    NPM_BINS.iter().find_map(|bin| {
        let real = fs::canonicalize(paths.at(bin)).ok()?;
        real.ancestors()
            .find(|a| a.file_name().is_some_and(|n| n == "node_modules"))
            .map(Path::to_path_buf)
    })
}

/// `rel` under the work user's home, when no part of it from the home down is a symlink and it is
/// a folder.
fn under_home(paths: &Paths, home: &str, rel: &str) -> Option<PathBuf> {
    let mut at = paths.at(home);
    for part in Path::new(rel).components() {
        let Component::Normal(part) = part else { return None };
        at.push(part);
        if !fs::symlink_metadata(&at).ok()?.is_dir() {
            return None;
        }
    }
    Some(at)
}

/// A folder's entry names, hidden ones left out.
fn entries(dir: &Path) -> Vec<String> {
    let Ok(read) = fs::read_dir(dir) else { return Vec::new() };
    read.flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| !n.starts_with('.'))
        .collect()
}

/// A `node_modules` folder's packages: each entry, a scope folder's as `@scope/name`.
fn packages(dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    for name in entries(dir) {
        if name.starts_with('@') {
            let scope = dir.join(&name);
            if fs::symlink_metadata(&scope).is_ok_and(|m| m.is_dir()) {
                out.extend(entries(&scope).into_iter().map(|p| format!("{name}/{p}")));
            }
        } else {
            out.push(name);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wakes_queued_while_a_pass_runs_count_as_one() {
        let (wake, woken) = mpsc::sync_channel(1);
        let handle = Additions { wake };
        handle.collect();
        handle.collect();
        handle.collect();
        drop(handle);
        let mut passes = 0;
        run(&woken, |_| passes += 1);
        assert_eq!(passes, 1);
    }
}
