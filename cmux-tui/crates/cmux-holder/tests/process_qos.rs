//! The holder process's QoS (p02-threads task 207): its loop runs at
//! QOS_CLASS_USER_INTERACTIVE, the echo path's class, and a shell it forks
//! starts at QOS_CLASS_DEFAULT (task 223). Another process's QoS class
//! cannot be read; the base priority the class sets can
//! (`cmux_threads::process::probe`).

#![cfg(target_vendor = "apple")]

use std::path::Path;

use cmux_holder::SpawnRequest;
use cmux_holder::client::{HolderClient, launch};
use cmux_threads::ThreadQos;
use cmux_threads::process::probe;

mod support;

const TOKEN: [u8; 32] = [0x27; 32];

#[test]
fn the_holder_runs_at_user_interactive_and_its_shell_at_default() {
    let default = probe::base_priority_at(ThreadQos::Default).unwrap();
    let interactive = probe::base_priority_at(ThreadQos::UserInteractive).unwrap();
    assert_ne!(default, interactive);

    let dir = support::unique_dir("cmhq");
    let socket = dir.join("h.sock");
    // The holder sets its class before `ready`, whatever this thread's is.
    let mut holder = launch(Path::new(env!("CARGO_BIN_EXE_cmux-holder")), &socket, &TOKEN).unwrap();
    let holder_priority = probe::first_thread_base_priority(holder.id() as libc::pid_t);

    let (mut client, listed) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert!(listed.is_empty());
    let request = SpawnRequest {
        cols: 80,
        rows: 24,
        cwd: b"/".to_vec(),
        argv: vec![b"/bin/sleep".to_vec(), b"30".to_vec()],
        env: vec![b"PATH=/bin:/usr/bin".to_vec()],
        ..SpawnRequest::default()
    };
    let (shell, _master) = client.spawn(1, &request).unwrap();
    let shell_priority = probe::first_thread_base_priority(shell);

    // SAFETY: signals the shell and the holder this test started.
    unsafe {
        libc::kill(shell, libc::SIGKILL);
    }
    drop(client);
    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(
        holder_priority.unwrap(),
        interactive,
        "holder: default {default}, user-interactive {interactive}"
    );
    assert_eq!(
        shell_priority.unwrap(),
        default,
        "shell: default {default}, user-interactive {interactive}"
    );
}
