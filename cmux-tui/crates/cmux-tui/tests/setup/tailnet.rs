//! `cmux setup tailnet` driven the way an agent drives it, against a fake
//! `tailscale` CLI in each state a new machine meets: not installed, the
//! daemon down, signed out, waiting for an admin's approval, a tagged node
//! with no owner, and signed in. Only `--dry-run` reaches the change, so no
//! test starts a real listener or installs a login service.

use std::path::{Path, PathBuf};

use serde_json::Value;

use super::World;

/// A fake `tailscale` at `<world>/tailscale`: `status --json` prints
/// `status` when it is Some, else fails the way the CLI does when
/// tailscaled is not running.
fn fake_tailscale(world: &World, status: Option<&str>) -> PathBuf {
    let path = world.home.parent().unwrap().join("tailscale");
    let body = match status {
        Some(json) => {
            let file = world.home.parent().unwrap().join("tailscale-status.json");
            std::fs::write(&file, json).unwrap();
            format!("#!/bin/sh\n[ \"$1\" = status ] && cat '{}' && exit 0\nexit 1\n", file.display())
        }
        None => "#!/bin/sh\necho 'failed to connect to local tailscaled; it doesn't appear to be running' >&2\nexit 1\n".to_owned(),
    };
    std::fs::write(&path, body).unwrap();
    make_executable(&path);
    path
}

fn make_executable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// `tailscale status --json` of this machine in `state`; tagged with
/// `tag:server` (no owner) when `tagged`.
fn status(state: &str, tagged: bool) -> String {
    let tags = if tagged { r#""Tags": ["tag:server"],"# } else { "" };
    format!(
        r#"{{"BackendState": "{state}",
  "Self": {{"HostName": "box", "DNSName": "box.example.ts.net.", "OS": "linux", {tags}
           "UserID": 7, "TailscaleIPs": ["100.64.0.9"], "Online": true}},
  "User": {{"7": {{"ID": 7, "LoginName": "person@example.com"}}}},
  "Peer": {{}}}}"#
    )
}

fn setup(world: &World, tailscale: &Path, args: &[&str]) -> Value {
    let mut all = vec!["setup", "tailnet"];
    all.extend_from_slice(args);
    let output = world.command(&all).env("CMUX_TAILSCALE_BIN", tailscale).output().unwrap();
    assert!(
        output.status.success(),
        "{all:?} exited {:?}: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!("{all:?}: {error}: {}", String::from_utf8_lossy(&output.stdout))
    })
}

/// Each state before the machine can serve hands the person exactly their
/// one step, and changes nothing.
#[test]
fn cmux_setup_tailnet_hands_the_person_the_one_tailscale_step_each_state_needs() {
    let world = World::new("tailnet-person");

    let missing = world.home.parent().unwrap().join("no-tailscale-here");
    let report = setup(&world, &missing, &[]);
    assert_eq!(report["task"], "tailnet", "{report}");
    assert_eq!(report["state"], "needs_user", "{report}");
    assert_eq!(report["user_action"]["kind"], "install", "{report}");
    assert_eq!(report["user_action"]["url"], "https://tailscale.com/download", "{report}");

    let down = fake_tailscale(&world, None);
    let report = setup(&world, &down, &[]);
    assert_eq!(report["state"], "needs_user", "{report}");
    assert_eq!(report["user_action"]["kind"], "start", "{report}");

    for (state, kind) in [("NeedsLogin", "sign_in"), ("Stopped", "sign_in"), ("NoState", "sign_in")]
    {
        let ts = fake_tailscale(&world, Some(&status(state, false)));
        let report = setup(&world, &ts, &[]);
        assert_eq!(report["state"], "needs_user", "{state}: {report}");
        assert_eq!(report["user_action"]["kind"], kind, "{state}: {report}");
        assert!(
            report["user_action"]["command"].as_str().unwrap().contains("tailscale up"),
            "{state}: {report}"
        );
    }

    let ts = fake_tailscale(&world, Some(&status("NeedsMachineAuth", false)));
    let report = setup(&world, &ts, &[]);
    assert_eq!(report["user_action"]["kind"], "approve", "{report}");
    assert_eq!(
        report["user_action"]["url"], "https://login.tailscale.com/admin/machines",
        "{report}"
    );

    // Nothing of the person's hosting config was written by any of these.
    assert!(!world.home.join(".cmux").join("host").join("remote.json").exists());
}

/// Signed in, a dry run names the change (`cmux host enable`) and its undo;
/// a tagged node has no owner, so setup asks for the person's login, and
/// with `--owner` plans it.
#[test]
fn cmux_setup_tailnet_plans_serving_this_machine_and_asks_a_tagged_node_for_its_owner() {
    let world = World::new("tailnet-plan");

    let ts = fake_tailscale(&world, Some(&status("Running", false)));
    let report = setup(&world, &ts, &["--dry-run"]);
    assert_eq!(report["state"], "planned", "{report}");
    assert_eq!(report["dry_run"], true, "{report}");
    assert_eq!(report["before"]["enabled"], false, "{report}");
    assert_eq!(report["before"]["tailnet"], "Running", "{report}");
    assert_eq!(report["owner"], "person@example.com", "{report}");
    assert_eq!(report["undo"], "cmux host disable --json", "{report}");
    assert_eq!(report["verify"], "cmux host dial box", "{report}");

    let tagged = fake_tailscale(&world, Some(&status("Running", true)));
    let report = setup(&world, &tagged, &["--dry-run"]);
    assert_eq!(report["state"], "needs_user", "{report}");
    assert_eq!(report["user_action"]["kind"], "owner", "{report}");
    assert!(
        report["user_action"]["command"].as_str().unwrap().contains("cmux setup tailnet --owner"),
        "{report}"
    );

    let report = setup(&world, &tagged, &["--owner", "person@example.com", "--dry-run"]);
    assert_eq!(report["state"], "planned", "{report}");
    assert_eq!(report["owner"], "person@example.com", "{report}");

    assert!(!world.home.join(".cmux").join("host").join("remote.json").exists());
}

/// `list` names `tailnet` as a task `setup` runs and the iPhone pairing
/// task; `status` reports the tailnet check; bad arguments exit 2.
#[test]
fn cmux_setup_tailnet_is_listed_checked_and_refuses_bad_arguments() {
    let world = World::new("tailnet-list");
    let list = world.json(&["setup", "list"]);
    let tasks = list["tasks"].as_array().unwrap();
    let task = |id: &str| tasks.iter().find(|t| t["id"] == id).cloned();
    let tailnet = task("tailnet").expect("tailnet task");
    assert_eq!(tailnet["setup"], "cmux setup tailnet [--owner LOGIN] [--dry-run]", "{tailnet}");
    let phone = task("phone").expect("phone task");
    assert!(
        phone["apply"].as_array().unwrap().iter().any(|a| a == "cmux cloud open-mobile-pairing"),
        "{phone}"
    );

    let ts = fake_tailscale(&world, Some(&status("Running", false)));
    let output =
        world.command(&["setup", "status"]).env("CMUX_TAILSCALE_BIN", &ts).output().unwrap();
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    let check = report["checks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["task"] == "tailnet")
        .cloned()
        .unwrap_or_else(|| panic!("no tailnet check: {report}"));
    assert_eq!(check["tailnet"], "Running", "{check}");
    assert_eq!(check["enabled"], false, "{check}");

    for args in [
        &["setup", "tailnet", "extra"][..],
        &["setup", "tailnet", "--owner"],
        &["setup", "tailnet", "--owner", ""],
        &["setup", "tailnet", "--nope"],
    ] {
        let output = world.command(args).env("CMUX_TAILSCALE_BIN", &ts).output().unwrap();
        assert_eq!(output.status.code(), Some(2), "{args:?}");
    }
}
