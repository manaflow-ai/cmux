use super::*;

#[test]
fn names_are_path_safe() {
    assert!(valid_name("ubuntu-24.04"));
    assert!(!valid_name("../etc"));
    assert!(!valid_name("a/b"));
    assert!(!valid_name(".hidden"));
    assert!(!valid_name(""));
}

#[test]
fn mmds_serves_the_machine_id_where_cmux_host_reads_it() {
    let id = new_id("vm");
    let data = mmds_data(&id);
    assert_eq!(data["latest"]["meta-data"]["instance-id"], id.as_str());
    let cfg = mmds_config();
    assert_eq!(cfg["version"], "V2");
    assert_eq!(cfg["network_interfaces"], json!(["eth0"]));
    // cmux-host accepts only [A-Za-z0-9._-]{1,128} as an instance id.
    assert!(id.len() <= 128);
    assert!(id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')));
}

/// A stand-in for Firecracker's vsock bridge and one guest agent connection: answers the
/// `CONNECT` line, reads one framed request, replies `reply(req)` and hands the request back.
fn fake_agent(
    name: &str,
    reply: fn(&GuestRequest) -> GuestResponse,
) -> (PathBuf, tokio::sync::oneshot::Receiver<GuestRequest>) {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
    let dir =
        std::env::temp_dir().join(format!("cmux-vmd-clock-test-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = dir.join("v.sock");
    let _ = std::fs::remove_file(&sock);
    let listener = tokio::net::UnixListener::bind(&sock).unwrap();
    let (tx, rx) = tokio::sync::oneshot::channel();
    tokio::spawn(async move {
        let (s, _) = listener.accept().await.unwrap();
        let mut s = BufReader::new(s);
        let mut line = String::new();
        s.read_line(&mut line).await.unwrap();
        assert_eq!(line, format!("CONNECT {}\n", crate::proto::GUEST_AGENT_PORT));
        s.get_mut().write_all(b"OK 1073741824\n").await.unwrap();
        let mut len = [0u8; 4];
        s.read_exact(&mut len).await.unwrap();
        let mut body = vec![0u8; u32::from_be_bytes(len) as usize];
        s.read_exact(&mut body).await.unwrap();
        let req: GuestRequest = serde_json::from_slice(&body).unwrap();
        let out = serde_json::to_vec(&reply(&req)).unwrap();
        s.get_mut().write_all(&(out.len() as u32).to_be_bytes()).await.unwrap();
        s.get_mut().write_all(&out).await.unwrap();
        let _ = tx.send(req);
    });
    (dir, rx)
}

fn unix_ns_now() -> u64 {
    u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()).unwrap()
}

/// A guest restored from a snapshot an hour old: the resume step sends it the host's time,
/// and the guest's answer (how far its clock moved) reaches the timings.
#[tokio::test]
async fn a_resumed_guest_gets_the_hosts_clock() {
    let (dir, seen) = fake_agent("set", |req| match req {
        GuestRequest::SetClock { unix_ns } => GuestResponse::Clock {
            stepped_ns: crate::proto::clock_step_ns(unix_ns - 3_600_000_000_000, *unix_ns),
        },
        _ => GuestResponse::Error { message: "not set_clock".into() },
    });
    let before = unix_ns_now();
    let clock = sync_clock(&dir.join("v.sock")).await;
    let after = unix_ns_now();
    assert_eq!(clock["stepped_ms"], 3_600_000, "{clock}");
    let GuestRequest::SetClock { unix_ns } = seen.await.unwrap() else {
        panic!("the host sent something other than set_clock")
    };
    assert!((before..=after).contains(&unix_ns), "{before} <= {unix_ns} <= {after}");
    std::fs::remove_dir_all(&dir).unwrap();
}

/// An agent from before set_clock answers "bad request": the resume still succeeds, and the
/// timings say why the clock was not set.
#[tokio::test]
async fn an_old_agent_without_set_clock_does_not_fail_the_resume() {
    let (dir, _seen) = fake_agent("old", |_| GuestResponse::Error {
        message: "bad request: unknown variant `set_clock`".into(),
    });
    let clock = sync_clock(&dir.join("v.sock")).await;
    assert!(clock["error"].as_str().unwrap().contains("unknown variant"), "{clock}");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn ids_are_path_safe() {
    assert!(valid_name(&new_id("vm")));
}
