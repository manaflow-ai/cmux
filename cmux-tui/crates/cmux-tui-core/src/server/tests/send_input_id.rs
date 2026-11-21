//! Lose a reply after the daemon has dispatched the send, then retry the same batch
//! from another connection. Read the real PTY slave to observe what the program got.
use super::*;
use base64::Engine;
use cmux_fault::Rng;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::os::fd::{AsRawFd, FromRawFd};

fn raw_input_pty() -> (File, File) {
    let (mut master, mut slave) = (-1, -1);
    // SAFETY: openpty initializes both descriptors on success. Each File below takes
    // ownership of one, and the termios calls use the live slave descriptor.
    unsafe {
        assert_eq!(
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            ),
            0,
            "openpty: {}",
            std::io::Error::last_os_error()
        );
        let master = File::from_raw_fd(master);
        let slave = File::from_raw_fd(slave);
        let mut termios: libc::termios = std::mem::zeroed();
        assert_eq!(libc::tcgetattr(slave.as_raw_fd(), &mut termios), 0);
        libc::cfmakeraw(&mut termios);
        // A lost delimiter must fail the assertion instead of hanging the suite.
        termios.c_cc[libc::VMIN] = 0;
        termios.c_cc[libc::VTIME] = 10;
        assert_eq!(libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios), 0);
        (master, slave)
    }
}

fn send_frame(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    frame: &Value,
) -> anyhow::Result<Value> {
    let cmd: Command = serde_json::from_value(frame.clone())?;
    handle_command(mux, client, cmd, writer)
}

fn replay_lost_send_replies(with_ids: bool) -> usize {
    let mux = test_mux();
    let surface = mux.new_workspace(Some("input".into()), Some((80, 24))).unwrap();
    let (master, slave) = raw_input_pty();
    surface.replace_input_writer_for_test(Box::new(master));
    let mut reader = BufReader::new(slave);
    let connections = [test_writer(), test_writer()].map(|writer| {
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        (client, writer)
    });
    let send = |message: &Value, connection: usize| {
        let (client, writer) = &connections[connection];
        send_frame(&mux, *client, writer, message).unwrap()
    };

    let delimiter = json!({"cmd":"send", "surface":surface.id, "text":"\n"});
    let mut duplicates = 0;
    for seed in 0..100 {
        let mut rng = Rng::new(seed);
        let initial_duplicates = duplicates;
        // Even if every reply in a group is lost, 50 four-byte batches plus
        // their retries fit in the smallest supported PTY input queue.
        for start in (0..1_000).step_by(50) {
            let mut expected = Vec::new();
            for number in start..start + 50 {
                let batch = format!("{number:04}");
                let mut message = json!({
                    "cmd": "send", "surface": surface.id,
                    "bytes": base64::engine::general_purpose::STANDARD.encode(batch.as_bytes())
                });
                if with_ids {
                    message["input_id"] = json!(format!("phone-{seed}:{number}"));
                }
                expected.extend_from_slice(batch.as_bytes());
                let reply = send(&message, 0);
                // The loss is after application, so the sender cannot tell whether to retry.
                if rng.chance(10) {
                    drop(reply);
                    let replay = send(&message, 1);
                    if with_ids {
                        assert_eq!(replay["duplicate"], true, "seed {seed}, batch {number}");
                    } else {
                        assert_eq!(replay, json!({}));
                        expected.extend_from_slice(batch.as_bytes());
                    }
                } else {
                    assert_ne!(reply["duplicate"], true, "seed {seed}, batch {number}");
                }
            }
            send(&delimiter, 0);
            expected.push(b'\n');
            let mut actual = Vec::new();
            reader.read_until(b'\n', &mut actual).unwrap();
            assert_eq!(actual, expected, "seed {seed}, starting batch {start}, ids {with_ids}");
            duplicates += (actual.len() - 1) / 4 - 50;
        }
        let label = if with_ids { "after" } else { "before" };
        for (metric, value) in [("dups", duplicates - initial_duplicates), ("holes", 0)] {
            println!(
                "{label} NETCOND {}",
                json!({"surface":"terminal", "profile":"reply-loss-10@1", "phase":"reconnect", "scale":"1x", "metric":metric, "value":value, "run":0, "seed":seed})
            );
        }
    }
    mux.shutdown();
    duplicates
}

#[test]
fn send_input_id_lost_replies_reach_the_pty_once_in_order() {
    let before = replay_lost_send_replies(false);
    let after = replay_lost_send_replies(true);
    assert_eq!(before, 9_890);
    assert_eq!(after, 0);
    eprintln!(
        "100 seeds × 1,000 batches: before {before} duplicates, 0 holes; after {after} duplicates, 0 holes"
    );
}

#[test]
fn send_input_id_racing_paste_and_submit_is_once_per_pty() {
    let mux = test_mux();
    let terminal = |name: &str| {
        let surface = mux.new_workspace(Some(name.into()), Some((80, 24))).unwrap();
        let (master, slave) = raw_input_pty();
        surface.replace_input_writer_for_test(Box::new(master));
        (surface.id, BufReader::new(slave))
    };
    let (first, mut first_reader) = terminal("first");
    let (second, mut second_reader) = terminal("second");
    let paste = |surface| {
        json!({
            "cmd":"send", "surface":surface, "text":"paste", "paste":true, "submit":true,
            "input_id":"phone:1"
        })
    };

    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let identity = send_frame(&mux, client, &writer, &json!({"cmd":"identify"})).unwrap();
    assert!(identity["capabilities"].as_array().unwrap().contains(&json!("send-input-id-v1")));
    for id in [String::new(), "x".repeat(129)] {
        let invalid =
            json!({"cmd":"send", "surface":first, "input_id":id, "text":"too long or empty"});
        assert!(send_frame(&mux, client, &writer, &invalid).is_err());
    }
    let malformed = json!({
        "cmd":"send", "surface":first, "input_id":"phone:1", "text":"bad prefix", "bytes":"!"
    });
    assert!(send_frame(&mux, client, &writer, &malformed).is_err());

    let start = Arc::new(std::sync::Barrier::new(2));
    let (sent, replies) = std::sync::mpsc::channel();
    for _ in 0..2 {
        let connection = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, connection.clone());
        let (mux, start, sent, frame) = (mux.clone(), start.clone(), sent.clone(), paste(first));
        std::thread::spawn(move || {
            start.wait();
            let _ = sent.send(send_frame(&mux, client, &connection, &frame));
        });
    }
    drop(sent);
    let mut duplicates = 0;
    for _ in 0..2 {
        let result = replies.recv_timeout(Duration::from_secs(5)).unwrap().unwrap();
        duplicates += usize::from(result["duplicate"] == true);
    }
    assert_eq!(duplicates, 1);
    assert_ne!(send_frame(&mux, client, &writer, &paste(second)).unwrap()["duplicate"], true);

    for (surface, reader) in [(first, &mut first_reader), (second, &mut second_reader)] {
        let end = json!({"cmd":"send", "surface":surface, "text":"\n"});
        send_frame(&mux, client, &writer, &end).unwrap();
        let mut bytes = Vec::new();
        reader.read_until(b'\n', &mut bytes).unwrap();
        assert_eq!(bytes, b"paste\r\n", "PTY {surface} received extra or missing input");
    }
    mux.shutdown();
}
