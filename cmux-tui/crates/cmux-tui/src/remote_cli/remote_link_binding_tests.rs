//! Exercise sidecar reuse with real local listeners and the production runtime.

use super::*;
use std::os::unix::net::UnixListener;

struct Sidecar {
    directory: tempfile::TempDir,
    runtime: crate::remote_runtime::DaemonRuntimeHandle,
    _mux: UnixListener,
    mux_path: PathBuf,
}

impl Sidecar {
    fn start() -> Self {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let mux_path = directory.path().join("first.sock");
        let mux = UnixListener::bind(&mux_path).unwrap();
        let runtime = start_daemon_runtime(
            mux_path.clone(),
            DaemonRuntimeOptions {
                session: "binding".into(),
                state_dir: Some(directory.path().join("state")),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                trusted_carrier_websocket: false,
                workspace_http: None,
                relays: Vec::new(),
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
            },
        )
        .unwrap();
        Self { directory, runtime, _mux: mux, mux_path }
    }

    fn attach(&self, mux: Option<&Path>) -> anyhow::Result<()> {
        let info = self.runtime.info();
        ensure_daemon(
            "binding",
            Some(&self.directory.path().join("state")),
            &info.state_dir,
            &info.link_socket,
            mux,
        )
        .map(|_| ())
    }
}

#[test]
fn remote_mux_binding_rejects_a_different_live_owner() {
    let sidecar = Sidecar::start();
    let other_path = sidecar.directory.path().join("second.sock");
    let _other = UnixListener::bind(&other_path).unwrap();
    let result = sidecar.attach(Some(&other_path));
    sidecar.runtime.shutdown().unwrap();
    assert!(result.is_err(), "reused a sidecar attached to a different mux owner");
}

#[test]
fn remote_mux_binding_rejects_a_missing_requested_owner() {
    let sidecar = Sidecar::start();
    let result = sidecar.attach(Some(&sidecar.directory.path().join("missing.sock")));
    sidecar.runtime.shutdown().unwrap();
    assert!(result.is_err(), "a live sidecar hid the requested daemon's disappearance");
}

#[test]
fn remote_mux_binding_ignores_forged_runtime_metadata() {
    let sidecar = Sidecar::start();
    let other_path = sidecar.directory.path().join("second.sock");
    let _other = UnixListener::bind(&other_path).unwrap();
    let path = sidecar.runtime.info().state_dir.join("runtime.json");
    let original = fs::read(&path).unwrap();
    let mut record: Value = serde_json::from_slice(&original).unwrap();
    record["mux_socket"] = serde_json::to_value(&other_path).unwrap();
    fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
    let result = sidecar.attach(Some(&other_path));
    fs::write(&path, original).unwrap();
    sidecar.runtime.shutdown().unwrap();
    assert!(result.is_err(), "caller-written runtime metadata selected a different mux owner");
}

#[test]
fn remote_mux_binding_requires_a_live_admin_responder() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let (state, link, _) = daemon_paths("binding", Some(directory.path())).unwrap();
    fs::create_dir_all(&state).unwrap();
    let _link = UnixListener::bind(&link).unwrap();
    let mux = directory.path().join("requested.sock");
    let _mux = UnixListener::bind(&mux).unwrap();
    let result = ensure_daemon("binding", Some(directory.path()), &state, &link, Some(&mux));
    assert!(result.is_err(), "accepted an unverified listener as the requested sidecar");
    assert!(link.exists(), "refusal removed the existing listener");
}

#[test]
fn remote_mux_binding_reuses_the_same_owner() {
    let sidecar = Sidecar::start();
    let result = sidecar.attach(Some(&sidecar.mux_path));
    sidecar.runtime.shutdown().unwrap();
    result.unwrap();
}

#[test]
fn remote_mux_binding_accepts_an_alias_of_the_same_socket() {
    let sidecar = Sidecar::start();
    let alias = sidecar.directory.path().join("alias.sock");
    std::os::unix::fs::symlink(&sidecar.mux_path, &alias).unwrap();
    let result = sidecar.attach(Some(&alias));
    sidecar.runtime.shutdown().unwrap();
    result.unwrap();
}

#[test]
fn remote_mux_binding_preserves_unqualified_reuse() {
    let sidecar = Sidecar::start();
    let result = sidecar.attach(None);
    sidecar.runtime.shutdown().unwrap();
    result.unwrap();
}
