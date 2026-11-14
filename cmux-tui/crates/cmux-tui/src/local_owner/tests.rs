use std::ffi::OsString;
use std::process::Command;

use super::cloud_backend_from_identity;
use super::configure_detached_owner_environment;
use serde_json::json;

#[test]
fn backend_identity_is_optional_for_classic_and_exact_for_next() {
    assert_eq!(cloud_backend_from_identity(&json!({"app":"cmux-tui"})), None);
    assert_eq!(
        cloud_backend_from_identity(&json!({"cloud_backend":"https://cloud-api-staging.cmux.dev"})),
        Some("https://cloud-api-staging.cmux.dev".to_owned())
    );
    assert_eq!(cloud_backend_from_identity(&json!({"cloud_backend": 7})), None);
}

#[cfg(unix)]
mod event_driven {
    use std::os::fd::IntoRawFd;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use super::super::*;

    #[test]
    fn ready_descriptor_is_claimed_close_on_exec_and_signaled_once() {
        let (mut reader, writer) = io::pipe().unwrap();
        let fd = writer.into_raw_fd();
        assert_eq!(claim_inherited_fd(OWNER_READY_FD_ARG, &fd.to_string()), Ok(fd));
        // SAFETY: querying flags of a descriptor this test owns.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        assert_ne!(flags & libc::FD_CLOEXEC, 0);
        signal_ready(fd);
        let mut bytes = Vec::new();
        reader.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, b"1");
        for invalid in ["0", "2", "-1", "x"] {
            assert!(claim_inherited_fd(OWNER_READY_FD_ARG, invalid).is_err(), "{invalid}");
        }
    }

    fn owner_state(command: &mut Command) -> (Arc<OwnerProcessState>, u32) {
        let child = command.spawn().unwrap();
        let pid = child.id();
        (Arc::new(OwnerProcessState { child: std::sync::Mutex::new(Some(child)) }), pid)
    }

    #[test]
    fn the_reaper_wakes_on_exit_and_leaves_no_zombie() {
        let (state, pid) = owner_state(&mut Command::new("true"));
        let reaper = {
            let state = Arc::clone(&state);
            std::thread::spawn(move || reap_on_exit(&state, pid))
        };
        reaper.join().unwrap();
        assert!(state.child.lock().unwrap().is_none());
        // SAFETY: probing a pid this test spawned and the reaper reaped.
        assert_eq!(unsafe { libc::kill(pid as libc::pid_t, 0) }, -1);
    }

    #[test]
    fn terminate_ends_a_blocked_reaper_and_the_owner() {
        let (state, pid) = owner_state(Command::new("sleep").arg("60"));
        let reaper = {
            let state = Arc::clone(&state);
            std::thread::spawn(move || reap_on_exit(&state, pid))
        };
        let started = Instant::now();
        SpawnedOwner { state: Arc::clone(&state), pid, ready: None }.terminate();
        reaper.join().unwrap();
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(state.child.lock().unwrap().is_none());
    }
}

#[test]
fn detached_owner_removes_terminal_identity_but_keeps_configuration() {
    let mut command = Command::new("cmux-tui");
    command
        .env("CMUX_SURFACE_ID", "surface")
        .env("CMUX_WORKSPACE_ID", "workspace")
        .env("CMUX_TAB_ID", "tab")
        .env("CMUX_PANEL_ID", "panel")
        .env("CMUX_PANE_ID", "pane")
        .env("CMUX_NEXT_CLOUD_LAUNCHER", "1")
        .env("CMUX_TUI_CONFIG", "/tmp/mux.json")
        .env("CMUX_MUX_CONFIG", "/tmp/legacy-mux.json");

    configure_detached_owner_environment(&mut command);

    let values = command
        .get_envs()
        .map(|(key, value)| (key.to_owned(), value.map(OsString::from)))
        .collect::<std::collections::HashMap<_, _>>();
    for key in
        ["CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID"]
    {
        assert_eq!(values.get(OsString::from(key).as_os_str()), Some(&None));
    }
    assert_eq!(values.get(OsString::from("CMUX_NEXT_CLOUD_LAUNCHER").as_os_str()), Some(&None));
    assert_eq!(
        values.get(OsString::from("CMUX_TUI_CONFIG").as_os_str()),
        Some(&Some(OsString::from("/tmp/mux.json")))
    );
    assert_eq!(
        values.get(OsString::from("CMUX_MUX_CONFIG").as_os_str()),
        Some(&Some(OsString::from("/tmp/legacy-mux.json")))
    );
}
