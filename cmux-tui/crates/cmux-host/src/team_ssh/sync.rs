//! The team VM's trust sync (team-vm-plan S5): with the binding from
//! [`super::enroll`], read `team_vm.ssh_ca` as the VM's own install every
//! [`SYNC_INTERVAL`] and apply it ([`super::store::apply`], then the
//! revoked-session reaper). A revocation reaches sshd within one interval;
//! a VM that cannot sync refuses new logins after
//! [`super::trust::STALE_AFTER_SECS`] (fail closed).

use std::time::Duration;

use serde_json::{Value, json};

use crate::cloud::client::{CloudClient, Http};
use crate::cloud::sender::Answer;
use crate::cloud::wire::Bound;
use crate::config::Paths;

use super::enroll::TeamBound;
use super::store::{self, Applied, KrlCheck};
use super::trust::Snapshot;

/// Between two syncs: four chances inside the 120 s fail-closed bound.
pub const SYNC_INTERVAL: Duration = Duration::from_secs(30);

/// The cloud client's view of the team binding (only the fields auth uses).
pub fn client_bound(b: &TeamBound) -> Bound {
    Bound {
        machine: b.instance_id.clone(),
        team: b.team.clone(),
        host: String::new(),
        epoch: b.epoch,
        install: b.install.clone(),
        user: b.user.clone(),
        grant: String::new(),
        env: b.env,
        api_origin: b.api_origin.clone(),
        keyset: Value::Null,
        bound_at: 0,
    }
}

/// One sync: the team's CA and KRL, refused unless they name this VM's team.
pub fn sync_once<H: Http>(
    client: &mut CloudClient<H>,
    paths: &Paths,
    check_krl: KrlCheck<'_>,
    now_wall_ms: u64,
) -> Result<Applied, String> {
    match client.read("team_vm.ssh_ca", &json!({}), now_wall_ms) {
        Answer::Transport => Err("team_vm.ssh_ca: no answer (token or network)".into()),
        Answer::Http { status: 200, body } => {
            let value = body.get("value").cloned().unwrap_or(Value::Null);
            if value["team"] != client.bound().team.as_str() {
                return Err("team_vm.ssh_ca answered for another team".into());
            }
            let snapshot: Snapshot =
                serde_json::from_value(value).map_err(|e| format!("team_vm.ssh_ca: {e}"))?;
            store::apply(paths, &snapshot, now_wall_ms / 1000, check_krl)
        }
        Answer::Http { status, body } => {
            let code = body["error"]["code"].as_str().or(body["code"].as_str()).unwrap_or("");
            Err(format!("team_vm.ssh_ca: HTTP {status} {code}"))
        }
    }
}

/// `cmux host team-ssh sync [--once]`: the loop the image's unit runs.
#[cfg(target_os = "linux")]
pub fn run(paths: &Paths, once: bool) -> u8 {
    use cmux_server::cloud_http::JsonPoster;
    use cmux_server_core::install_key::SystemRandom;

    use crate::cloud::role::PosterHttp;

    let wall_ms = || {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64)
    };
    let mut client: Option<(TeamBound, CloudClient<PosterHttp>)> = None;
    loop {
        let bound = super::enroll::machine_instance(paths)
            .ok()
            .and_then(|instance| super::enroll::load_bound(paths, &instance));
        match bound {
            None => {
                client = None;
                if once {
                    eprintln!("cmux host team-ssh sync: this machine has no team binding");
                    return 3;
                }
                wait_for_binding(paths);
                continue;
            }
            Some(b) if client.as_ref().is_none_or(|(have, _)| *have != b) => {
                let made = SystemRandom::new();
                let key = super::enroll::team_key(paths, &b.instance_id, &made);
                let http = JsonPoster::new().map(PosterHttp);
                match (key, http) {
                    (Ok(key), Ok(http)) => {
                        client = Some((b.clone(), CloudClient::new(http, client_bound(&b), key)));
                    }
                    (Err(e), _) | (_, Err(e)) => eprintln!("cmux host team-ssh sync: {e}"),
                }
            }
            Some(_) => {}
        }
        let mut code = 1;
        if let Some((_, c)) = client.as_mut() {
            match sync_once(c, paths, &store::ssh_keygen_check, wall_ms()) {
                Ok(applied) => {
                    let host = super::linux_host::LinuxHost::new(paths.at(super::SESSIONS_DIR));
                    let reaped = super::sessions::reap(paths, &host);
                    if applied.krl_changed
                        || !reaped.ended.is_empty()
                        || !reaped.linger_off.is_empty()
                        || !reaped.managers_stopped.is_empty()
                    {
                        eprintln!(
                            "cmux host team-ssh sync: krl_version {} generation {} ended {:?} linger_off {:?} managers_stopped {:?}",
                            applied.state.krl_version,
                            applied.state.generation,
                            reaped.ended,
                            reaped.linger_off,
                            reaped.managers_stopped
                        );
                    }
                    for e in &reaped.errors {
                        eprintln!("cmux host team-ssh sync: {e}");
                    }
                    code = if reaped.errors.is_empty() { 0 } else { 1 };
                }
                Err(e) => eprintln!("cmux host team-ssh sync: {e}"),
            }
        }
        if once {
            return code;
        }
        std::thread::sleep(SYNC_INTERVAL);
    }
}

/// Blocks until something changes in the binding's directory (no polling
/// on machines that never get a team binding).
#[cfg(target_os = "linux")]
fn wait_for_binding(paths: &Paths) {
    let dir = paths.at(super::enroll::TEAM_BOUND_FILE);
    let Some(dir) = dir.parent() else { return };
    let _ = std::fs::create_dir_all(dir);
    match crate::linux::fds::Inotify::new().and_then(|i| i.watch_dir(dir).map(|_| i)) {
        Ok(inotify) => {
            // A blocking read: returns on the next event in the directory.
            if super::enroll::machine_instance(paths)
                .ok()
                .and_then(|i| super::enroll::load_bound(paths, &i))
                .is_none()
            {
                let mut pfd = libc::pollfd { fd: inotify.raw(), events: libc::POLLIN, revents: 0 };
                // SAFETY: one valid pollfd; -1 blocks until the directory changes.
                unsafe {
                    libc::poll(&mut pfd, 1, -1);
                }
                let _ = inotify.read_events();
            }
        }
        Err(_) => std::thread::sleep(SYNC_INTERVAL),
    }
}
