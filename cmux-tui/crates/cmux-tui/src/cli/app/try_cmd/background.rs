//! Stage signed NIGHTLY daemon binaries without touching the running app. The caller
//! retains the channel cache for the lifetime of the experiment.

use std::path::Path;
use std::time::{Duration, Instant};

use cmux_host::updater::channel;

use super::{GlobalArgs, Live, app_commit, live, now, read_live};
use serde_json::json;

const ATTEMPT: &str = "nightly-automatic-attempt.json";

fn readiness(global: &GlobalArgs, app: &Path, activity: bool) -> Result<(bool, bool), String> {
    let (_, stream) = super::find_app(global, Some(app));
    let mut stream = stream.ok_or("the selected app did not answer")?;
    let reply = super::super::exchange(
        &mut stream,
        "updates.daemon.readiness",
        json!({"activity": activity}),
        super::super::READ_TIMEOUT,
    )?
    .map_err(|err| format!("readiness refused: {err}"))?;
    Ok((
        reply["enabled"].as_bool().ok_or("missing enabled state")?,
        reply["quiet"].as_bool().ok_or("missing activity state")?,
    ))
}

pub(super) fn follow(global: &GlobalArgs, app: &Path) -> Result<(), String> {
    let store = super::store_for(Some(app)).ok_or("missing build-specific store")?;
    let mut follower = Follower::default();
    // A disconnected or replaced app cannot authorize a swap. Once its parent exits,
    // the app's worker exits too, including while the control socket is unavailable.
    let parent = unsafe { libc::getppid() };
    while parent > 1 && unsafe { libc::getppid() } == parent {
        match readiness(global, app, false) {
            Ok((false, _)) => return Ok(()),
            Ok((true, _)) => {
                if let Err(reason) = follower.check(global, app, &store) {
                    crate::client_log::info("nightly-daemon-updates", &reason);
                }
            }
            Err(reason) => crate::client_log::info("nightly-daemon-updates", &reason),
        }
        std::thread::sleep(Duration::from_secs(15));
    }
    Ok(())
}

fn read_pointer(cache: &mut channel::Cache) -> Result<live::ChannelPayload, String> {
    let (etag, modified) = cache.validators();
    let mut request = cmux_process::Command::new("curl");
    request.args([
        "-fsS",
        "--include",
        "--proto",
        "=https",
        "--max-time",
        "12",
        "--max-filesize",
        &live::LIVE_MAX_BYTES.to_string(),
    ]);
    if let Some(tag) = etag {
        request.args(["-H", &format!("If-None-Match: {tag}")]);
    }
    if let Some(date) = modified {
        request.args(["-H", &format!("If-Modified-Since: {date}")]);
    }
    let response = request.arg(live::channel_url()).output().map_err(|e| e.to_string())?;
    if !response.status.success() {
        return Err(format!("nightly-live request failed ({})", response.status));
    }
    cache.take_verified(channel::parse_response(&response.stdout)?, |bytes| {
        live::verify_channel(bytes, &channel::trusted_keys(), now())
    })
}

/// A pending candidate owns the immutable commit and its verified file list. A quiet-point
/// retry of the same pointer needs only a conditional request, even with large binaries.
#[derive(Default)]
pub(super) struct Follower {
    cache: channel::Cache,
    pending: Option<(live::ChannelPayload, Vec<live::Change>)>,
}

impl Follower {
    pub(super) fn stage(
        &mut self,
        app: &Path,
        store: &live::Store,
    ) -> Result<Option<&(live::ChannelPayload, Vec<live::Change>)>, String> {
        let pointer = read_pointer(&mut self.cache)?;
        let build = app_commit(app).ok_or("missing app commit")?;
        if !live::takes(&pointer.live_from, &build)
            || !live::channel_is_newer(store.channel_last()?, pointer.committed_at)
            || !live::channel_is_newer(store.watermark(ATTEMPT)?, pointer.committed_at)
        {
            self.pending = None;
            return Ok(None);
        }
        if self.pending.as_ref().map(|(p, _)| p) != Some(&pointer) {
            self.pending = None;
            let base = live::files_base();
            let manifest = match read_live(&pointer.commit, &base) {
                Live::Found(manifest) => manifest,
                Live::Missing => return Err("missing per-commit manifest".into()),
                Live::Refused(reason) => return Err(reason),
            };
            if !live::takes(&manifest.live_from, &build) {
                return Err("per-commit manifest excludes this app".into());
            }
            let mut changes = Vec::new();
            for wanted in live::wanted(&manifest, &base)? {
                let to = store.fetch(&wanted)?;
                changes.push(live::Change {
                    file: wanted.file,
                    to: to.zip(wanted.binary.map(|b| b.sha256)),
                    expect: None,
                });
            }
            self.pending = Some((pointer, changes));
        }
        Ok(self.pending.as_ref())
    }

    fn check(
        &mut self,
        global: &GlobalArgs,
        app: &Path,
        store: &live::Store,
    ) -> Result<(), String> {
        let Some((pointer, changes)) = self.stage(app, store)? else { return Ok(()) };
        let started = Instant::now();
        super::apply_channel(app, store, pointer, false, |app_build| {
            // Read after taking the common try/undo lock: the setting or activity
            // may have changed while downloading or while another try held it.
            if pointer.expires_at <= now() || readiness(global, app, true)? != (true, true) {
                return Err("waiting for a current pointer and quiet app".into());
            }
            let mut daemon = super::app_daemon(app);
            daemon.cli.set_file_name("cmux-tui");
            let socket = daemon.socket.as_deref().ok_or("no daemon socket for this app")?;
            let reports_commit =
                |pid| crate::cli::lifecycle::owner_reports_commit(socket, pid, &pointer.commit);
            // Persist before touching the bundle. A crash or rollback must never
            // start a second automatic swap of the same signed commit.
            if !live::channel_is_newer(store.watermark(ATTEMPT)?, pointer.committed_at) {
                return Err("this channel update was already attempted".into());
            }
            let sessions = super::session_handoff::discover(&daemon)?;
            if pointer.expires_at <= now() || readiness(global, app, true)? != (true, true) {
                return Err("the quiet point ended while probing session daemons".into());
            }
            store.record_watermark(ATTEMPT, pointer.committed_at, &pointer.commit)?;
            let mut phases = live::Phases::default();
            let result = live::apply_verified(
                app,
                changes,
                store,
                &daemon,
                &mut phases,
                Some(&reports_commit),
            )
            .and_then(|applied| {
                super::session_handoff::finish(
                    sessions,
                    applied,
                    app,
                    app_build,
                    Some(&pointer.commit),
                    store,
                    &daemon,
                    &mut phases,
                )
            });
            let receipt = json!({"schema": 1, "action": "try", "target": pointer.commit,
                "commit": pointer.commit, "path": "live", "channel": pointer.channel,
                "app": app, "app_commit": app_build, "at": now()});
            let mut changed = false;
            if super::finish(
                global,
                store,
                receipt,
                result,
                phases,
                started,
                &pointer.commit,
                app,
                Some(&mut changed),
            ) != 0
            {
                return Err("background daemon update failed; see the app-try receipt".into());
            }
            Ok(changed)
        })?;
        Ok(())
    }
}
