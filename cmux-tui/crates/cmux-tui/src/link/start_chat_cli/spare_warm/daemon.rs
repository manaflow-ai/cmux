//! The daemon's `cloud-spare-warm` (cmux-tui-core `server/cloud_spare_warm.rs`): the App's Cloud
//! intent runs the same ledger and platform call as `cmux link start-chat warm-spare`, in the
//! daemon process, and the login copy it hands out runs here too ([`super::login_copy`]), so the
//! App spawns no process and its main actor waits on nothing.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_tui_core::Mux;
use cmux_tui_core::server::cloud_spare_warm::{
    CopyGuard, ReservationParams, SpareWarmParams, SpareWarmService,
};
use serde_json::Value;

use super::{Request, answer, login_copy, now_ms, post};

/// The installed service: the start-chat state folder is read on every call, as the CLI does.
struct DaemonSpareWarm;

/// Installs `cloud-spare-warm-v1` on the daemon's mux.
pub(crate) fn install(mux: &Arc<Mux>) {
    if !mux.install_spare_warm(Arc::new(DaemonSpareWarm)) {
        crate::client_log::stderr_log!("startup", "cloud spare warm: already installed");
    }
}

impl SpareWarmService for DaemonSpareWarm {
    fn reservation(&self, params: ReservationParams) -> Value {
        super::super::reservations::daemon(
            params.request,
            params.release,
            &params.access_token,
            &params.install_token,
        )
    }

    fn warm(&self, params: SpareWarmParams, guard: Arc<dyn CopyGuard>) -> Value {
        let Some(ledger) = super::super::ledger::path() else {
            return super::refused(
                "ledger_failed",
                "this Mac has no state folder for the spare warm",
            );
        };
        let state = ledger.parent().map_or_else(|| ledger.clone(), Path::to_path_buf);
        warm(params, &state, guard, &post, &|params, state, guard, machine, team| {
            std::thread::Builder::new()
                .name("cloud-warm-login-copy".into())
                .spawn(move || copy_then_report(&params, &state, &*guard, &machine, &team))
                .is_ok()
        })
    }
}

/// Starts the copy the answer hands out on its own thread; false when it could not start.
type Spawn<'a> = &'a dyn Fn(SpareWarmParams, PathBuf, Arc<dyn CopyGuard>, String, String) -> bool;

/// The ledger's answer to `params` (a warm, or the claim of `params.claimed`), and the copy it
/// hands out started with `spawn`. A copy that cannot start is reported abandoned at once, so the
/// next warm answers it again and no start waits on it.
fn warm(
    params: SpareWarmParams,
    state: &Path,
    guard: Arc<dyn CopyGuard>,
    transport: super::Transport<'_>,
    spawn: Spawn<'_>,
) -> Value {
    let request = Request {
        platform: Some(params.platform.clone()),
        account: params.account.clone(),
        abandoned: None,
        finished: None,
        installed: None,
        wait_copy: None,
        login_receipt: None,
        claimed: params.claimed.clone(),
    };
    let reply =
        answer(request, &params.access_token, &params.install_token, state, now_ms(), transport);
    let copy = reply.get("copy").and_then(|copy| {
        let machine = copy.get("machine")?.as_str()?.to_owned();
        let team = copy.get("team")?.as_str()?.to_owned();
        (copy.get("account")?.as_str()? == params.account).then_some((machine, team))
    });
    if let Some((machine, team)) = copy {
        let report = params.clone();
        if !spawn(params, state.to_path_buf(), guard, machine.clone(), team) {
            end(&report, state, &machine, End::Abandoned, transport);
        }
    }
    reply
}

/// The copy, then its end to the ledger: installed (the start's receipt), finished when it ended
/// for good, abandoned when it was ended meanwhile (the next warm answers it again).
fn copy_then_report(
    params: &SpareWarmParams,
    state: &Path,
    guard: &dyn CopyGuard,
    machine: &str,
    team: &str,
) {
    let still_person = || guard.still(&params.account);
    let consent = || guard.consent();
    let installed = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => {
            let live = login_copy::Live { params, machine, team, runtime };
            let (installed, summary) = login_copy::copy(params, &still_person, &consent, &live);
            crate::client_log::stderr_log!(
                "cloud",
                "{}: harness login {summary}",
                login_copy::STEP
            );
            installed
        }
        Err(_) => false,
    };
    let ended = if installed {
        End::Installed
    } else if still_person() {
        End::Finished
    } else {
        End::Abandoned
    };
    end(params, state, machine, ended, &post);
}

/// How a copy ended: installed (the ledger keeps it as the start's login receipt), done otherwise
/// (or given up for good), or abandoned (the next warm answers it again).
#[derive(Clone, Copy, PartialEq, Eq)]
enum End {
    Installed,
    Finished,
    Abandoned,
}

/// Reports the copy onto `machine` ended to the ledger.
fn end(
    params: &SpareWarmParams,
    state: &Path,
    machine: &str,
    ended: End,
    transport: super::Transport<'_>,
) {
    let named = |end: End| (ended == end).then(|| machine.to_owned());
    let request = Request {
        platform: Some(params.platform.clone()),
        account: params.account.clone(),
        abandoned: named(End::Abandoned),
        finished: named(End::Finished),
        installed: named(End::Installed),
        wait_copy: None,
        login_receipt: None,
        claimed: None,
    };
    let _ =
        answer(request, &params.access_token, &params.install_token, state, now_ms(), transport);
}

#[cfg(test)]
#[path = "daemon_tests.rs"]
mod tests;
