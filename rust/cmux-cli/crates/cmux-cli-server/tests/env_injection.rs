//! Programs spawned inside a tab should see `CMUX_WORKSPACE_ID`,
//! `CMUX_TAB_ID`, and the `CMX_*` aliases in their environment. Agents
//! (Claude Code, Codex, etc.) use these to identify which workspace/tab
//! they're running in without walking the socket.
//!
//! The test asks the shell to dump the env vars into a tempfile. Reading
//! the file avoids flakiness from frame-cell positioning corrupting the
//! rendered ANSI stream.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn spawned_shell_sees_workspace_and_tab_env_vars() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let env_dump = dir.path().join("env.txt");
    let env_dump_tab2 = dir.path().join("env-tab2.txt");

    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        // Wide viewport so the printf-and-redirect command fits on one
        // line inside the pane (sidebar + borders eat columns).
        initial_viewport: (240, 40),
        snapshot_path: None,
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });
    wait_for_socket(&socket).await;

    let stream = UnixStream::connect(&socket).await.unwrap();
    let (read_half, mut w) = stream.into_split();
    let mut r = BufReader::new(read_half);
    write_msg(
        &mut w,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport {
                cols: 240,
                rows: 40,
            },
            token: None,
        },
    )
    .await
    .unwrap();
    // Drain server messages in a background task. The server keeps
    // pushing frames; without a reader the macOS Unix-socket send
    // buffer (~8KB) fills up and the server blocks mid-write.
    let drain =
        tokio::spawn(
            async move { while let Ok(Some(_)) = read_msg::<_, ServerMsg>(&mut r).await {} },
        );

    // Give the shell a moment to draw its first prompt before we
    // send input. The PTY buffers input if the shell isn't reading
    // yet, but some shells drop stdin if they haven't initialised.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let script = format!(
        "printf 'WS=%s\\nTAB=%s\\nCMX_WS=%s\\nCMX_TAB=%s\\n' \"$CMUX_WORKSPACE_ID\" \"$CMUX_TAB_ID\" \"$CMX_WORKSPACE_ID\" \"$CMX_TAB_ID\" > {}\n",
        env_dump.display(),
    );
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: script.into_bytes(),
        },
    )
    .await
    .unwrap();

    // Give the shell time to start + resize after the initial attach;
    // the SIGWINCH from daemon.resize can race with the first Input.
    let contents = wait_for_file(&env_dump, Duration::from_secs(15)).await;
    let lines: Vec<&str> = contents.lines().collect();
    assert_env_line(&lines, "WS");
    assert_env_line(&lines, "TAB");
    assert_env_line(&lines, "CMX_WS");
    assert_env_line(&lines, "CMX_TAB");

    // Open a second tab; verify the new child sees CMUX_TAB_ID incremented
    // but the same workspace id — catches regressions where the workspace
    // id is mis-threaded through Workspace::new_tab.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::NewTab,
        },
    )
    .await
    .unwrap();
    // The drain task is consuming the server's stream; wait long
    // enough for the new tab's shell to have started and bound its
    // env before we send it input.
    tokio::time::sleep(Duration::from_millis(500)).await;

    let script2 = format!(
        "printf 'WS=%s\\nTAB=%s\\n' \"$CMUX_WORKSPACE_ID\" \"$CMUX_TAB_ID\" > {}\n",
        env_dump_tab2.display(),
    );
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: script2.into_bytes(),
        },
    )
    .await
    .unwrap();

    let c2 = wait_for_file(&env_dump_tab2, Duration::from_secs(5)).await;
    let l2: Vec<&str> = c2.lines().collect();
    let ws1 = env_value(&lines, "WS");
    let ws2 = env_value(&l2, "WS");
    let tab1 = env_value(&lines, "TAB");
    let tab2 = env_value(&l2, "TAB");
    assert_eq!(ws1, ws2, "new tab should carry the same workspace id");
    assert_ne!(tab1, tab2, "new tab should have a distinct tab id");

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    drain.abort();
    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

fn assert_env_line(lines: &[&str], key: &str) {
    let line = lines.iter().find(|l| l.starts_with(&format!("{key}=")));
    let Some(l) = line else {
        panic!("{key}= not found in env dump: {lines:?}");
    };
    let v = &l[key.len() + 1..];
    assert!(
        v.chars().all(|c| c.is_ascii_digit()) && !v.is_empty(),
        "{key}={v:?} is not a numeric id (env var missing or empty)",
    );
}

fn env_value<'a>(lines: &'a [&'a str], key: &str) -> &'a str {
    lines
        .iter()
        .find(|l| l.starts_with(&format!("{key}=")))
        .map(|l| &l[key.len() + 1..])
        .unwrap_or("")
}

async fn wait_for_file(path: &std::path::Path, deadline: Duration) -> String {
    let end = tokio::time::Instant::now() + deadline;
    loop {
        if let Ok(s) = std::fs::read_to_string(path)
            && !s.trim().is_empty()
        {
            return s;
        }
        if tokio::time::Instant::now() > end {
            panic!("{} never appeared within deadline", path.display());
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn wait_for_socket(socket: &std::path::Path) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not appear");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}
