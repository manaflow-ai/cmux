//! The cmux vault's pull thread (`vault.rs`), off the poll loop: at bind (its spawn), on every resume
//! ([`VaultPull::wake`]), then every minute while it works. A failure backs off (5 s doubling to 10 min); a
//! vault that is off where this machine lives (404 `vault.not_found`, production today) is looked at again
//! hourly, and says so once. A line is logged only when it differs from the last one: names and codes, never
//! a value.
//!
//! Each pull reads the session host's layout marker (`/etc/cmux/daemon-layout`: whose home, as
//! `daemon_noise_key.rs` reads it for the public half) and its identity file's private key, zeroed after the
//! pull; it writes that home's `~/.config/cmux/machine-secrets.env` as the session user ([`SecretsFile`]),
//! keeps its state in [`STATE_FILE`] (root's, 0600), and once the vault owns a name makes the login profile
//! hook ([`ensure_profile_hook`]) so shells and acpmux's login environment read the file without a
//! `.cmux/machine.toml`. The thread ends when the worker drops its [`VaultPull`] (a rebind replaces it).
//!
//! [`STATE_FILE`]: super::vault::STATE_FILE

use std::path::Path;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::time::Duration;

use super::client::{CloudClient, Http, Store};
use super::sender::Backoff;
use super::vault::{Outcome, note, pull_once};
use super::vault_file::{PROFILE_HOOK, SecretsFile, ensure_profile_hook};
use crate::config::{LAYOUT_MARKER_FILE, Paths};
use crate::daemon_spec::{ROOT_HOME, SESSION, WORK_USER};
use crate::linux::spawn::lookup_user;

/// The pull's interval while it works.
pub const EVERY: Duration = Duration::from_secs(60);
/// The interval while the vault is off where this machine lives.
pub const OFF_EVERY: Duration = Duration::from_secs(60 * 60);

/// Wakes the thread (a resume); dropping it ends the thread.
pub struct VaultPull {
    wake: SyncSender<()>,
}

impl VaultPull {
    pub fn spawn<H: Http + Send + 'static, S: Store + Send + 'static>(
        mut client: CloudClient<H>,
        paths: Paths,
        mut store: S,
        now_wall_ms: fn() -> u64,
        random: fn() -> f64,
        log: fn(&str),
    ) -> std::io::Result<VaultPull> {
        let (wake, woken) = mpsc::sync_channel(1);
        std::thread::Builder::new().name("cmux-host-vault".to_owned()).spawn(move || {
            let machine = client.bound().machine.clone();
            let mut backoff = Backoff::new(5_000, 600_000);
            let mut last = String::new();
            let mut hook_made = false;
            run(&woken, |resumed| {
                if resumed {
                    // A pooled connection from before a pause is dead and nothing says so.
                    client.reset_transport();
                }
                let outcome = pass(&paths, &machine, &mut store, |path| {
                    client.get_as_install(path, now_wall_ms())
                });
                if let Outcome::Applied { applied, kept, .. } = &outcome
                    && !(applied.written.is_empty() && kept.is_empty())
                    && !hook_made
                {
                    match ensure_profile_hook(&paths.at(PROFILE_HOOK)) {
                        Ok(wrote) => {
                            hook_made = true;
                            if wrote {
                                log(&format!(
                                    "vault: {PROFILE_HOOK} written (login shells read the names)"
                                ));
                            }
                        }
                        Err(code) => log(&format!("vault: login profile not written ({code})")),
                    }
                }
                let line = note(&outcome);
                if line != last {
                    log(&line);
                    last = line;
                }
                match outcome {
                    Outcome::Applied { .. } => {
                        backoff.reset();
                        EVERY
                    }
                    Outcome::Off => {
                        backoff.reset();
                        OFF_EVERY
                    }
                    Outcome::Failed(_) => Duration::from_millis(backoff.next(0, random())),
                }
            });
        })?;
        Ok(VaultPull { wake })
    }

    /// A resume: pull now, off this thread.
    pub fn wake(&self) {
        // Full: a pull is already due. Disconnected: the thread ended.
        let _ = self.wake.try_send(());
    }
}

/// The first pass at once, then one per wake or when the delay the last pass gave runs out; wakes queued
/// meanwhile count as one. `pass(true)` after a wake.
fn run(woken: &Receiver<()>, mut pass: impl FnMut(bool) -> Duration) {
    let mut delay = pass(false);
    loop {
        match woken.recv_timeout(delay) {
            Ok(()) => {
                while woken.try_recv().is_ok() {}
                delay = pass(true);
            }
            Err(RecvTimeoutError::Timeout) => delay = pass(false),
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

/// One pull on `paths`' root: the session host's home and user from the layout marker, its private key from
/// its identity file (zeroed when this returns).
pub fn pass(
    paths: &Paths,
    machine: &str,
    store: &mut dyn Store,
    get: impl FnOnce(&str) -> super::sender::Answer,
) -> Outcome {
    let marker = std::fs::read_to_string(paths.at(LAYOUT_MARKER_FILE)).ok();
    let Some(home) = super::daemon_noise_key::session_home(marker.as_deref()) else {
        return Outcome::Failed("vault.no_layout");
    };
    let owner = if home == Path::new(ROOT_HOME) {
        Some((0, 0))
    } else {
        lookup_user(WORK_USER).map(|u| (u.uid, u.gid))
    };
    let Some((uid, gid)) = owner else { return Outcome::Failed("vault.no_user") };
    let identity = super::daemon_noise_key::identity_path(&home, SESSION);
    let key = super::daemon_noise_key::read_private(&paths.at(&identity.to_string_lossy()));
    let mut env = SecretsFile { home: paths.at(&home.to_string_lossy()), uid, gid };
    pull_once(get, machine, key.as_deref(), store, &mut env)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_resume_pulls_now_and_queued_wakes_count_as_one() {
        let (wake, woken) = mpsc::sync_channel(1);
        let handle = VaultPull { wake };
        handle.wake();
        handle.wake();
        drop(handle);
        let mut passes = Vec::new();
        run(&woken, |resumed| {
            passes.push(resumed);
            EVERY
        });
        // The first pass at spawn, then one for the queued wake; the dropped handle ends it.
        assert_eq!(passes, [false, true]);
    }
}
