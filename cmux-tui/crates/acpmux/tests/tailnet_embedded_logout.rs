//! Exercise the library's shipped Controller, not a cfg(test) replacement.
#![cfg(all(unix, feature = "tailnet"))]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No daemon and no agent: the controller only edits its own state folder.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

mod tailnet {
    mod embedded {
        use acpmux::tailnet::embedded::Controller;
        use std::os::unix::fs::{PermissionsExt, symlink};

        #[tokio::test]
        async fn shipped_logout_removes_saved_identity_without_starting_a_node() {
            let home = tempfile::tempdir().unwrap();
            let state = home.path().join("tailnet");
            std::fs::create_dir(&state).unwrap();
            std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
            std::fs::write(state.join("enabled"), b"1").unwrap();
            std::fs::write(state.join("tailscaled.state"), b"saved identity").unwrap();
            let controller = Controller::new(&state, "test");
            assert_eq!(controller.logout().await.unwrap().state, "stopped");
            assert!(!state.join("tailscaled.state").exists());
            assert!(!state.join("enabled").exists());
            assert!(controller.node().is_none());
            assert_eq!(controller.logout().await.unwrap().state, "stopped");
        }

        #[tokio::test]
        async fn shipped_logout_of_an_untouched_installation_creates_nothing() {
            let home = tempfile::tempdir().unwrap();
            let state = home.path().join("tailnet");
            let controller = Controller::new(&state, "test");
            assert_eq!(controller.logout().await.unwrap().state, "stopped");
            assert!(!state.exists());
        }

        #[tokio::test]
        async fn shipped_logout_refuses_symlinks_before_deleting_any_file() {
            let home = tempfile::tempdir().unwrap();
            let unrelated = tempfile::tempdir().unwrap();
            std::fs::write(unrelated.path().join("enabled"), b"keep enabled").unwrap();
            std::fs::write(unrelated.path().join("tailscaled.state"), b"keep identity").unwrap();
            let state = home.path().join("tailnet");
            symlink(unrelated.path(), &state).unwrap();
            let controller = Controller::new(&state, "test");
            assert!(
                controller.logout().await.unwrap_err().contains("private tailnet state directory")
            );
            assert_eq!(std::fs::read(unrelated.path().join("enabled")).unwrap(), b"keep enabled");
            assert_eq!(
                std::fs::read(unrelated.path().join("tailscaled.state")).unwrap(),
                b"keep identity"
            );
        }
    }
}
