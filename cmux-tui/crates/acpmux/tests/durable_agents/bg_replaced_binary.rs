//! A background task after an update replaced the daemon's binary (`self_command.rs`). On
//! 2026-11-01 huge-blue's daemon ran from `~/.local/bin/acpmux (deleted)` and every `bg_start`
//! failed with "start the task's runner: No such file or directory": the runner was started
//! from `current_exe`, a path that no longer existed. It now starts from the open inode.

use super::*;

#[tokio::test]
async fn a_background_task_starts_after_an_update_replaced_the_daemons_binary() {
    let mut daemon = Daemon::new("bgexe", "approve-all");
    daemon.sigterm();
    let copy = daemon.home.join("bin").join("acpmux");
    std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
    std::fs::copy(daemon_env::bin(), &copy).unwrap();
    daemon.exe = copy.clone();
    daemon.start();
    let session = new_session(&daemon).await;
    let token = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;

    // The update: the old file is unlinked and another build takes its path.
    std::fs::remove_file(&copy).unwrap();
    std::fs::write(&copy, "#!/bin/sh\nexit 1\n").unwrap();
    std::fs::set_permissions(&copy, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();

    let mut caller = daemon.rpc().await;
    caller
        .call(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": session, "token": token}}}}),
        )
        .await;
    let params = json!({"sessionId": session, "command": "echo started; sleep 60"});
    let started = caller.reply("_acpmux/bg/start", params).await;
    let task = started["result"]["id"].as_str().unwrap_or_else(|| panic!("{started}")).to_owned();
    assert_eq!(started["result"]["state"], "running", "{started}");
    let stop = json!({"sessionId": session, "id": task});
    let stopped = caller.reply("_acpmux/bg/stop", stop).await;
    assert_eq!(stopped["result"]["state"], "stopped", "{stopped}");
}
