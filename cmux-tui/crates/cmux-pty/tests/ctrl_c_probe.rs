//! Throwaway diagnostic (dogfood-ctrlc): where a_pty_child_gets_sigint_from_ctrl_c stops on macOS.
#![cfg(unix)]

use std::io::{Read, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use cmux_pty::{NativePtyChild, PtyCommand, PtySize};

static STAGE: AtomicUsize = AtomicUsize::new(0);

fn stage(n: usize, what: &str, start: Instant) {
    STAGE.store(n, Ordering::SeqCst);
    eprintln!("probe stage {n} at {:?}: {what}", start.elapsed());
}

#[test]
fn ctrl_c_probe() {
    let start = Instant::now();
    let me = std::process::id();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(25));
        eprintln!("probe WATCHDOG: stuck at stage {}", STAGE.load(Ordering::SeqCst));
        let out = std::process::Command::new("/bin/ps")
            .args(["-A", "-o", "pid,ppid,pgid,sess,tpgid,stat,tty,wchan,command"])
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout);
        let mut pids = vec![me.to_string()];
        for _ in 0..4 {
            for line in text.lines() {
                let cols: Vec<&str> = line.split_whitespace().collect();
                if cols.len() > 2
                    && pids.iter().any(|p| p == cols[1])
                    && !pids.iter().any(|p| p == cols[0])
                {
                    pids.push(cols[0].to_string());
                }
            }
        }
        for line in text.lines() {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if line.contains("PID") || (!cols.is_empty() && pids.iter().any(|p| p == cols[0])) {
                eprintln!("probe ps: {line}");
            }
        }
        std::process::exit(3);
    });
    stage(1, "open", start);
    let pair =
        cmux_pty::open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }).unwrap();
    stage(2, "spawn", start);
    let mut command = PtyCommand::new("/bin/sh");
    command.args(["-c", "echo ready; ps -o pid,pgid,sess,tpgid,stat,tty -p $$; exec sleep 30"]);
    let mut spawned = pair.spawn(command).unwrap();
    let pid = spawned.child.process_id().unwrap();
    stage(3, &format!("spawned pid {pid}; reading"), start);
    let mut reader = spawned.master.try_clone_reader().unwrap();
    let mut output = Vec::new();
    let mut buffer = [0u8; 1024];
    while !String::from_utf8_lossy(&output).contains("sleep")
        && !String::from_utf8_lossy(&output).contains("TTY")
    {
        match reader.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => output.extend_from_slice(&buffer[..n]),
        }
        if String::from_utf8_lossy(&output).lines().count() >= 3 {
            break;
        }
    }
    stage(4, &format!("read {:?}", String::from_utf8_lossy(&output)), start);
    let foreground = spawned.master.process_group_leader();
    stage(5, &format!("foreground {foreground:?}; taking writer"), start);
    let mut writer = spawned.master.take_writer().unwrap();
    stage(6, "writing 0x03", start);
    writer.write_all(b"\x03").unwrap();
    writer.flush().unwrap();
    stage(7, "waiting", start);
    let child: &mut dyn cmux_pty::Child = &mut *spawned.child;
    let child = child.downcast_mut::<NativePtyChild>().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = child.try_wait_native().unwrap() {
            break Some(status);
        }
        if Instant::now() >= deadline {
            break None;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    stage(8, &format!("status {status:?}"), start);
    if status.is_none() {
        let _ = spawned.child.kill();
        stage(9, "killed", start);
        let _ = spawned.child.wait();
    }
    stage(10, "dropping writer", start);
    drop(writer);
    stage(11, "done", start);
}
