// The agent-tab attach against a real acpmux, not the fake: what its session lists cost on a
// daemon you run yourself. Ignored by default; no CI job runs it. Point it at a running
// acpmux and a session of it:
//
//   CMUX_REAL_ACPMUX_SOCKET=/path/acpmux.sock CMUX_REAL_ACPMUX_SESSION=<id> \
//     cargo test -p cmux-tui-core real_acpmux -- --ignored --nocapture
//
// The daemon's socket is reached through a relay that passes every line through unchanged
// and counts the session lists (`_acpmux/watch`, `_acpmux/sessions`) the attach asked for:
// their calls, rows and reply bytes, and whether one carried a gated field. It prints one
// `real-acpmux-attach {...}` JSON line. Included by agent_session_attach_tests.rs.

/// One request the attach sent through the relay, and the size of its reply.
#[derive(Clone, Debug, Default)]
struct RelayedCall {
    method: String,
    params: Value,
    rows: Option<usize>,
    reply_bytes: usize,
}

/// A unix-socket relay to `target` that records each request and its reply.
fn counting_relay(target: PathBuf) -> (PathBuf, Arc<Mutex<Vec<RelayedCall>>>) {
    let directory = PathBuf::from(format!("/tmp/cmux-real-acpmux-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let socket = directory.join("r.sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let calls: Arc<Mutex<Vec<RelayedCall>>> = Arc::default();
    let shared = calls.clone();
    std::thread::spawn(move || {
        for client in listener.incoming() {
            let Ok(client) = client else { return };
            let daemon = UnixStream::connect(&target).expect("the real acpmux socket");
            // Request ids are per connection: each connection keys its own.
            let open: Arc<Mutex<HashMap<u64, usize>>> = Arc::default();
            let (up_open, up_calls) = (open.clone(), shared.clone());
            let (mut up_out, up_in) = (daemon.try_clone().unwrap(), client.try_clone().unwrap());
            std::thread::spawn(move || {
                for line in BufReader::new(up_in).lines() {
                    let Ok(line) = line else { break };
                    if let Ok(frame) = serde_json::from_str::<Value>(&line)
                        && let (Some(id), Some(method)) =
                            (frame["id"].as_u64(), frame["method"].as_str())
                    {
                        let mut calls = up_calls.lock().unwrap();
                        up_open.lock().unwrap().insert(id, calls.len());
                        calls.push(RelayedCall {
                            method: method.to_owned(),
                            params: frame["params"].clone(),
                            ..RelayedCall::default()
                        });
                    }
                    if writeln!(up_out, "{line}").is_err() {
                        break;
                    }
                }
                let _ = up_out.shutdown(Shutdown::Write);
            });
            let down_calls = shared.clone();
            let mut down_out = client;
            std::thread::spawn(move || {
                let mut reader = BufReader::new(daemon);
                let mut line = Vec::new();
                loop {
                    line.clear();
                    match reader.read_until(b'\n', &mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    if let Ok(frame) = serde_json::from_slice::<Value>(&line)
                        && frame.get("method").is_none()
                        && let Some(id) = frame["id"].as_u64()
                        && let Some(index) = open.lock().unwrap().remove(&id)
                        && let Some(call) = down_calls.lock().unwrap().get_mut(index)
                    {
                        call.reply_bytes = line.len();
                        call.rows = frame["result"]["sessions"].as_array().map(Vec::len);
                    }
                    if down_out.write_all(&line).is_err() {
                        break;
                    }
                }
                let _ = down_out.shutdown(Shutdown::Both);
            });
        }
    });
    (socket, calls)
}

#[test]
#[ignore = "needs a running acpmux: CMUX_REAL_ACPMUX_SOCKET and CMUX_REAL_ACPMUX_SESSION"]
fn real_acpmux_attach_session_list_reads() {
    let target = PathBuf::from(std::env::var("CMUX_REAL_ACPMUX_SOCKET").expect("the socket"));
    let session = std::env::var("CMUX_REAL_ACPMUX_SESSION").expect("a session of that acpmux");
    let label = std::env::var("CMUX_REAL_ACPMUX_LABEL").unwrap_or_default();
    let (relay, calls) = counting_relay(target);
    let mux = Mux::new_for_test("asa-real-acpmux", crate::SurfaceOptions::default());
    mux.set_acpmux_socket(Some(relay));
    let surface = agent_tab(&mux, Some(&session));
    let mut client = Client::connect(&mux, "real-acpmux");
    let started = Instant::now();
    let reply = client.request(json!({"cmd":"agent-session-attach","surface":surface,"limit":400,
                                      "kinds":["transcript"]}));
    let attach_ms = started.elapsed().as_millis();
    assert_eq!(reply["ok"], json!(true), "{reply}");
    // Any list the attach still reads after its reply.
    std::thread::sleep(Duration::from_millis(500));
    let calls = calls.lock().unwrap().clone();
    let lists: Vec<&RelayedCall> = calls
        .iter()
        .filter(|c| matches!(c.method.as_str(), "_acpmux/watch" | "_acpmux/sessions"))
        .collect();
    let gated = |c: &RelayedCall| {
        agent_session_attach::agent_session_link::list_gate::GATED_FIELDS
            .iter()
            .filter(|(field, _)| c.params.get(*field).is_some())
            .map(|(field, _)| *field)
            .collect::<Vec<_>>()
    };
    let report = json!({
        "label": label,
        "attachMs": attach_ms,
        "methods": calls.iter().map(|c| c.method.clone()).collect::<Vec<_>>(),
        "listCalls": lists.len(),
        "rows": lists.iter().filter_map(|c| c.rows).sum::<usize>(),
        "bytes": lists.iter().map(|c| c.reply_bytes).sum::<usize>(),
        "gatedFieldsSent": lists.iter().copied().flat_map(gated).collect::<Vec<_>>(),
        "lists": lists.iter().map(|c| json!({"method": c.method, "params": c.params,
                                             "rows": c.rows, "bytes": c.reply_bytes}))
                      .collect::<Vec<_>>(),
    });
    println!("real-acpmux-attach {report}");
}
