//! `Remote` against fake machines: progress, budgets, limits, encodings, and the copy's
//! patience (a late answer, a silent machine, a dropped connection).

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};

use super::{PART_BYTES, Remote};

/// A part in flight on a slow link reports progress before its answer:
/// the machine takes the first MiB of one 8 MiB `fs.write` and waits to
/// hear of progress before taking the rest. Progress only after each
/// answer (the 30 s upload idle killing a healthy slow upload) never
/// comes, and the machine records that.
#[test]
fn a_part_in_flight_reports_progress_before_its_answer() {
    let (client, mut server) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let (tick, ticks) = std::sync::mpsc::channel::<()>();
    let machine = std::thread::spawn(move || {
        let mut head = vec![0u8; 1 << 20];
        server.read_exact(&mut head).unwrap();
        let heard = ticks.recv_timeout(Duration::from_secs(5)).is_ok();
        let mut rest = Vec::new();
        BufReader::new(server.try_clone().unwrap()).read_until(b'\n', &mut rest).unwrap();
        let line = [head, rest].concat();
        let request: Value = serde_json::from_slice(&line).unwrap();
        let answer =
            json!({"id": request["id"], "ok": true, "data": {"entry": {"revision": "r1"}}});
        server.write_all(format!("{answer}\n").as_bytes()).unwrap();
        heard
    });
    let mut remote = Remote::on(client);
    let data = vec![7u8; PART_BYTES];
    let mut progress = || {
        let _ = tick.send(());
    };
    let revision = remote
        .write_with_progress("/work/f.bin", &mut data.as_slice(), 0o600, &mut progress)
        .unwrap();
    assert_eq!(revision, "r1");
    assert!(machine.join().unwrap(), "no progress while the part was in flight");
}

/// A part the link's forwarder took whole is still crossing to the
/// machine, so its answer comes later than one socket timeout. Machine
/// update copied the cmux-tui build this way and failed with "Resource
/// temporarily unavailable (os error 35)": the socket's read timeout
/// (EAGAIN) was taken for the call's failure. The machine here takes the
/// whole request at once, then answers after five read timeouts.
#[test]
fn an_answer_slower_than_one_read_timeout_is_still_waited_for() {
    let (client, mut server) = UnixStream::pair().unwrap();
    let timeout = Duration::from_millis(100);
    client.set_read_timeout(Some(timeout)).unwrap();
    client.set_write_timeout(Some(Duration::from_secs(20))).unwrap();
    let machine = std::thread::spawn(move || {
        let mut line = Vec::new();
        BufReader::new(server.try_clone().unwrap()).read_until(b'\n', &mut line).unwrap();
        let request: Value = serde_json::from_slice(&line).unwrap();
        std::thread::sleep(timeout * 5);
        let answer =
            json!({"id": request["id"], "ok": true, "data": {"entry": {"revision": "r1"}}});
        server.write_all(format!("{answer}\n").as_bytes()).unwrap();
    });
    let mut remote = Remote::on(client);
    let data = vec![7u8; 256 * 1024];
    let revision = remote.write("/work/cmux-tui", &mut data.as_slice(), 0o755).unwrap();
    assert_eq!(revision, "r1");
    machine.join().unwrap();
}

/// A machine that never answers still fails, once the request's budget
/// is spent, and says so instead of "os error 35".
#[test]
fn a_machine_that_never_answers_fails_with_what_stalled() {
    let mut remote = hostile(|requests, _| {
        requests.next();
    });
    remote.reader.get_ref().set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let started = std::time::Instant::now();
    let error = remote.stat("/work").unwrap_err().to_string();
    assert!(error.contains("did not answer"), "{error}");
    assert!(!error.contains("os error"), "{error}");
    assert!(started.elapsed() < Duration::from_secs(5), "waited {:?}", started.elapsed());
}

/// What a fake machine does with one request ([`machine`]).
enum Reply {
    /// Answers it `ok` after this long.
    After(Duration),
    /// Never answers it, and keeps the connection open.
    Never,
    /// Closes the connection under it, unanswered.
    Drop,
}

/// A fake machine daemon on a real socket: each connection on its own thread, each request
/// handed to `reply` with the connection's number (from 0) and the request. Returns the
/// socket's folder (kept for the test) and its path.
fn machine(
    reply: impl Fn(usize, &Value) -> Reply + Send + Sync + 'static,
) -> (cmux_unix_socket::TestDir, std::path::PathBuf) {
    let dir = cmux_unix_socket::short_test_dir("syncpat");
    let socket = dir.path().join("machine.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let reply = std::sync::Arc::new(reply);
    std::thread::spawn(move || {
        for (number, stream) in listener.incoming().enumerate() {
            let Ok(mut stream) = stream else { return };
            let reply = reply.clone();
            std::thread::spawn(move || {
                let reader = BufReader::new(stream.try_clone().unwrap());
                for line in reader.lines().map_while(Result::ok) {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    match reply(number, &request) {
                        Reply::After(wait) => {
                            std::thread::sleep(wait);
                            let answer = json!({"id": request["id"], "ok": true,
                                                "data": {"entry": {"revision": "r1"}, "kind": "dir"}});
                            if stream.write_all(format!("{answer}\n").as_bytes()).is_err() {
                                return;
                            }
                        }
                        Reply::Never => std::thread::sleep(Duration::from_secs(60)),
                        Reply::Drop => {
                            let _ = stream.shutdown(std::net::Shutdown::Both);
                            return;
                        }
                    }
                }
            });
        }
    });
    (dir, socket)
}

/// A [`Remote`] to `socket` with the copy's patience compressed: a 50 ms read timeout stands
/// for the 60 s one (a factor of 1,200).
fn patient(socket: &std::path::Path) -> Remote {
    let mut remote = Remote::connect(socket).unwrap();
    remote.reader.get_ref().set_read_timeout(Some(Duration::from_millis(50))).unwrap();
    remote.patience = super::Patience {
        ceiling: Duration::from_secs(10),
        stale: Duration::from_secs(5),
        probe: Duration::from_millis(200),
        reconnect: Duration::from_millis(400),
        replays: 4,
    };
    remote
}

/// A machine that answers a small request after 225 s at full scale (about 190 ms here, the
/// matrix's 5-file folder failed after 224 s on "did not answer within 60 s") while it
/// answers `ping` beside it: the request waits and gets its answer.
#[test]
fn a_late_answer_from_a_machine_that_still_answers_is_waited_for() {
    let (_dir, socket) = machine(|_, request| match request["cmd"].as_str() {
        Some("ping") => Reply::After(Duration::ZERO),
        _ => Reply::After(Duration::from_millis(190)),
    });
    let mut remote = patient(&socket);
    assert_eq!(remote.kind("/work").unwrap().as_deref(), Some("dir"));
}

/// A machine that stopped answering (no answer, and none to a ping) fails the request
/// within one silence and one probe, long before the ceiling.
#[test]
fn a_machine_that_stopped_answering_fails_fast() {
    let (_dir, socket) = machine(|_, _| Reply::Never);
    let mut remote = patient(&socket);
    let started = std::time::Instant::now();
    let error = format!("{:#}", remote.stat("/work").unwrap_err());
    assert!(error.contains("stopped answering"), "{error}");
    assert!(started.elapsed() < Duration::from_secs(3), "waited {:?}", started.elapsed());
}

/// However alive the machine stays, one request ends at the ceiling.
#[test]
fn a_live_machine_that_never_answers_the_request_ends_at_the_ceiling() {
    let (_dir, socket) = machine(|_, request| match request["cmd"].as_str() {
        Some("ping") => Reply::After(Duration::ZERO),
        _ => Reply::Never,
    });
    let mut remote = patient(&socket);
    remote.patience.ceiling = Duration::from_millis(400);
    let error = format!("{:#}", remote.stat("/work").unwrap_err());
    assert!(error.contains("though it still answers"), "{error}");
}

/// The machine drops the connection under a copy's writes (the matrix's 20,000-file
/// folder: "the machine daemon closed the connection" after 390 s): the copy dials again
/// and sends each dropped write again on the new connection, and every file lands.
#[test]
fn a_connection_dropped_mid_copy_is_dialed_again_and_the_copy_goes_on() {
    let writes = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = writes.clone();
    let (_dir, socket) = machine(move |connection, request| {
        if request["cmd"] == "fs.write" {
            let seen = counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            // The first connection drops on its third write, the second on its first.
            if (connection == 0 && seen == 2) || (connection == 1 && seen == 3) {
                return Reply::Drop;
            }
        }
        Reply::After(Duration::ZERO)
    });
    let mut remote = patient(&socket);
    for file in 0..6 {
        let data = vec![file as u8; 1024];
        let revision =
            remote.write(&format!("/work/f{file}"), &mut data.as_slice(), 0o644).unwrap();
        assert_eq!(revision, "r1");
    }
    // Six files, two of them sent twice.
    assert_eq!(writes.load(std::sync::atomic::Ordering::SeqCst), 8);
}

/// A machine whose socket is gone for good fails the copy once the reconnect window passes,
/// saying the connection dropped and did not come back.
#[test]
fn a_connection_that_never_comes_back_fails_after_the_window() {
    let (dir, socket) = machine(|_, request| match request["cmd"].as_str() {
        Some("fs.stat") => Reply::Drop,
        _ => Reply::After(Duration::ZERO),
    });
    let mut remote = patient(&socket);
    std::fs::remove_file(&socket).unwrap();
    let started = std::time::Instant::now();
    let error = format!("{:#}", remote.stat("/work").unwrap_err());
    assert!(error.contains("did not come back"), "{error}");
    assert!(error.contains("closed the connection"), "{error}");
    assert!(started.elapsed() < Duration::from_secs(3), "waited {:?}", started.elapsed());
    drop(dir);
}

/// An append, or the first part of a file written in parts, is never sent again: its first
/// copy may still land after the replay and the appends that follow it. A whole file's single
/// overwrite and a listing's first page are.
#[test]
fn only_whole_file_overwrites_and_reads_are_sent_again() {
    use super::replayable;
    let write = |mode: &str, path: &str| json!({"mode": mode, "path": path});
    assert!(replayable("fs.write", &write("overwrite", "/work/a.rs")));
    assert!(!replayable("fs.write", &write("append", "/work/.a.bin.cmux-sync-part")));
    assert!(!replayable("fs.write", &write("overwrite", "/work/.a.bin.cmux-sync-part")));
    assert!(replayable("fs.list", &json!({"path": "/work"})));
    assert!(!replayable("fs.list", &json!({"listing": "l", "cursor": "c"})));
    assert!(replayable("fs.stat", &json!({"path": "/work"})));
    for cmd in ["fs.rename", "fs.delete", "fs.mkdir", "fs.symlink", "blob.fetch.start"] {
        assert!(!replayable(cmd, &json!({})), "{cmd}");
    }
}

/// The machine answers pings but this connection stays silent (a link that redialed and left
/// the old stream open): past `stale` the connection counts as dropped, and the request is
/// sent again on a new one, which answers.
#[test]
fn a_connection_silent_while_the_machine_answers_is_replaced() {
    let (_dir, socket) = machine(|connection, request| match request["cmd"].as_str() {
        Some("ping") => Reply::After(Duration::ZERO),
        Some("fs.stat") if connection == 0 => Reply::Never,
        _ => Reply::After(Duration::ZERO),
    });
    let mut remote = patient(&socket);
    remote.patience.stale = Duration::from_millis(300);
    assert_eq!(remote.kind("/work").unwrap().as_deref(), Some("dir"));
}

/// A request that is not safe to send twice (a rename) is not sent again after a drop.
#[test]
fn a_rename_is_not_sent_again_after_a_drop() {
    let (_dir, socket) = machine(|_, request| match request["cmd"].as_str() {
        Some("fs.rename") => Reply::Drop,
        _ => Reply::After(Duration::ZERO),
    });
    let mut remote = patient(&socket);
    let error =
        format!("{:#}", remote.call("fs.rename", json!({"path": "/a", "name": "b"})).unwrap_err());
    assert!(error.contains("closed the connection"), "{error}");
}

/// A [`Remote`] whose machine is `serve`: it gets each request and the
/// connection to answer on, then the connection stays open (a machine
/// that hangs) until the test ends.
fn hostile(
    serve: impl FnOnce(&mut dyn Iterator<Item = Value>, &mut UnixStream) + Send + 'static,
) -> Remote {
    let (client, mut server) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    std::thread::spawn(move || {
        let reader = BufReader::new(server.try_clone().unwrap());
        let mut requests =
            reader.lines().map_while(Result::ok).map(|line| serde_json::from_str(&line).unwrap());
        serve(&mut requests, &mut server);
        std::thread::sleep(Duration::from_secs(30));
    });
    Remote::on(client)
}

/// An answer line that never ends is refused, not held in memory.
#[test]
fn an_answer_line_over_the_limit_is_refused() {
    let mut remote = hostile(|requests, server| {
        requests.next();
        let chunk = vec![b'x'; 1 << 20];
        for _ in 0..20 {
            if server.write_all(&chunk).is_err() {
                return;
            }
        }
    });
    let error = remote.call("fs.stat", json!({"path": "/x"})).unwrap_err();
    assert!(format!("{error:#}").contains("too long"), "{error:#}");
}

/// Answers that never carry the request's id are refused.
#[test]
fn answers_for_other_requests_are_refused() {
    let mut remote = hostile(|requests, server| {
        requests.next();
        for _ in 0..2000 {
            let line = format!("{}\n", json!({"id": 999, "ok": true, "data": {}}));
            if server.write_all(line.as_bytes()).is_err() {
                return;
            }
        }
    });
    let error = remote.call("fs.stat", json!({"path": "/x"})).unwrap_err();
    assert!(format!("{error:#}").contains("other requests"), "{error:#}");
}

/// A machine whose `identify` lists `capabilities` and that answers every
/// `fs.write` with a revision; the returned channel gets each write.
fn recording(capabilities: Value) -> (Remote, std::sync::mpsc::Receiver<Value>) {
    let (seen, writes) = std::sync::mpsc::channel();
    let remote = hostile(move |requests, server| {
        for request in requests {
            let data = match request["cmd"].as_str() {
                Some("identify") => json!({"capabilities": capabilities}),
                Some("fs.write") => {
                    let _ = seen.send(request.clone());
                    json!({"entry": {"revision": "r1"}})
                }
                _ => json!({"entry": {"revision": "r1"}}),
            };
            let answer = json!({"id": request["id"], "ok": true, "data": data});
            if server.write_all(format!("{answer}\n").as_bytes()).is_err() {
                return;
            }
        }
    });
    (remote, writes)
}

fn decoded(request: &Value) -> Vec<u8> {
    use base64::Engine as _;
    let wire = base64::engine::general_purpose::STANDARD
        .decode(request["bytes_base64"].as_str().unwrap())
        .unwrap();
    if request["encoding"] != json!("deflate") {
        return wire;
    }
    let mut out = Vec::new();
    std::io::Read::read_to_end(&mut flate2::read::DeflateDecoder::new(wire.as_slice()), &mut out)
        .unwrap();
    assert_eq!(request["decoded_size"], json!(out.len()));
    out
}

/// A machine without `fs-write-deflate-v1` (every image before it) gets
/// plain base64 writes, exactly the old request.
#[test]
fn a_machine_without_the_capability_gets_plain_base64() {
    let (mut remote, writes) = recording(json!(["fs-v1"]));
    remote.negotiate();
    let text = "fn main() {}\n".repeat(10_000);
    remote.write("/work/main.rs", &mut text.as_bytes(), 0o644).unwrap();
    let request = writes.recv().unwrap();
    assert!(request.get("encoding").is_none(), "{request}");
    assert!(request.get("decoded_size").is_none(), "{request}");
    assert!(request.get("no_follow").is_none(), "{request}");
    assert_eq!(decoded(&request), text.as_bytes());
}

/// With `fs-write-nofollow-v1` every write says `no_follow`: the one of
/// a small file, and each part and append of a large one.
#[test]
fn a_machine_with_no_follow_writes_gets_it_on_every_part() {
    let (mut remote, writes) = recording(json!(["fs-v1", "fs-write-nofollow-v1"]));
    remote.negotiate();
    assert!(remote.no_follow() && !remote.deflate);
    remote.write("/work/small.rs", &mut b"x".as_slice(), 0o644).unwrap();
    assert_eq!(writes.recv().unwrap()["no_follow"], true);
    let data = vec![1u8; PART_BYTES + 1];
    remote.write("/work/big.bin", &mut data.as_slice(), 0o644).unwrap();
    let first = writes.recv().unwrap();
    let append = writes.recv().unwrap();
    assert_eq!(
        (first["mode"].as_str(), append["mode"].as_str()),
        (Some("overwrite"), Some("append"))
    );
    assert_eq!((&first["no_follow"], &append["no_follow"]), (&json!(true), &json!(true)));
}

/// With the capability, text goes compressed and the parts of a file
/// over one part still decode to the file; bytes that do not shrink go
/// as they are.
#[test]
fn a_machine_with_the_capability_gets_deflate_for_what_shrinks() {
    let (mut remote, writes) = recording(json!(["fs-v1", "fs-write-deflate-v1"]));
    remote.negotiate();
    let text: Vec<u8> = "let value = compute(input);\n".repeat(400_000).into_bytes();
    assert!(text.len() > PART_BYTES);
    remote.write("/work/big.rs", &mut text.as_slice(), 0o755).unwrap();
    let mut rebuilt = Vec::new();
    let mut wire = 0;
    for _ in 0..text.len().div_ceil(PART_BYTES) {
        let request = writes.recv().unwrap();
        assert_eq!(request["encoding"], "deflate", "{}", request["mode"]);
        wire += request["bytes_base64"].as_str().unwrap().len();
        rebuilt.extend(decoded(&request));
    }
    assert!(rebuilt == text, "the parts do not decode to the file");
    assert!(wire * 20 < text.len(), "{wire} wire bytes for {}", text.len());

    let mut noise = vec![0u8; 256 * 1024];
    getrandom::fill(&mut noise).unwrap();
    remote.write("/work/blob.pack", &mut noise.as_slice(), 0o644).unwrap();
    let request = writes.recv().unwrap();
    assert!(request.get("encoding").is_none(), "noise was compressed");
    assert_eq!(decoded(&request), noise);
}

/// A listing that cycles cursors is refused promptly.
#[test]
fn a_listing_with_a_repeated_cursor_is_refused() {
    let mut remote = hostile(|requests, server| {
        for (page, request) in requests.enumerate().take(5000) {
            let answer = json!({"id": request["id"], "ok": true, "data": {
                "entries": [{"name": format!("n{page}"), "kind": "file", "size": 1, "mtime": 1}],
                "cursor": "c1",
                "listing": "l",
            }});
            if server.write_all(format!("{answer}\n").as_bytes()).is_err() {
                return;
            }
        }
    });
    let error = remote.list("/x").unwrap_err();
    assert!(format!("{error:#}").contains("no progress"), "{error:#}");
}
