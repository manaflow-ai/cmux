use super::*;

/// A fake MCP server: answers each request with its pid and the request's method, and asks its
/// client for `roots/list` after `notifications/initialized`.
const SERVER: &str = r#"
import sys, json, os
for l in sys.stdin:
    m = json.loads(l)
    if m.get("method") == "subscriptions/listen":
        sub = {"io.modelcontextprotocol/subscriptionId": m["id"]}
        print(json.dumps({"jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged", "params": {"_meta": sub}}), flush=True)
    elif m.get("method") == "notifications/initialized":
        print(json.dumps({"jsonrpc": "2.0", "id": 77, "method": "roots/list"}), flush=True)
    elif "method" in m and "id" in m:
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"pid": os.getpid(), "m": m["method"]}}), flush=True)
    elif "id" in m:
        print(json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {"answered": m["id"]}}), flush=True)
"#;

async fn read(r: &mut tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>) -> Value {
    let l = tokio::time::timeout(Duration::from_secs(10), r.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    serde_json::from_str(&l).unwrap()
}

#[tokio::test]
async fn chats_share_one_server_with_their_own_ids() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("p.sock");
    let spec = Spec {
        command: "python3".into(),
        args: vec!["-c".into(), SERVER.into()],
        ..Default::default()
    };
    let key = spec.key();
    specs().lock().unwrap().insert(key.clone(), spec);
    let listener = bind(&sock).unwrap();
    let pool = new_pool(dir.path());
    pool.scope.spawn_named("test pool", serve(pool.clone(), listener));

    let mut chats = Vec::new();
    let mut pids = Vec::new();
    for n in 0..3 {
        let s = UnixStream::connect(&sock).await.unwrap();
        let (r, mut w) = s.into_split();
        let mut r = BufReader::new(r).lines();
        w.write_all(format!("{key}\n").as_bytes()).await.unwrap();
        w.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{}}\n")
            .await
            .unwrap();
        let init = read(&mut r).await;
        assert_eq!(init["id"], 0);
        w.write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")
            .await
            .unwrap();
        if n == 0 {
            // Only the first chat's `initialized` reaches the server, so one roots request, to it.
            let ask = read(&mut r).await;
            assert_eq!(ask["method"], "roots/list");
            let given = ask["id"].clone();
            w.write_all(
                format!("{{\"jsonrpc\":\"2.0\",\"id\":{given},\"result\":{{\"roots\":[]}}}}\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
            let note = read(&mut r).await;
            assert_eq!(note["params"]["answered"], 77, "the server sees its own id back");
        }
        w.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"tools/list\"}\n")
            .await
            .unwrap();
        let v = read(&mut r).await;
        assert_eq!(v["id"], "x", "each chat keeps its own id");
        pids.push(v["result"]["pid"].clone());
        chats.push((r, w));
    }
    assert!(pids.windows(2).all(|p| p[0] == p[1]), "one server for every chat: {pids:?}");
    pool.scope.token().cancel();
}

/// MCP 2026-07-28 chats skip `initialize` and open `subscriptions/listen`: each sees its own ack,
/// under its own listen id, and no other chat's.
#[tokio::test]
async fn each_chat_gets_its_own_subscription_ack() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("p.sock");
    let spec = Spec {
        command: "python3".into(),
        args: vec!["-c".into(), SERVER.into(), "listen".into()],
        ..Default::default()
    };
    let key = spec.key();
    specs().lock().unwrap().insert(key.clone(), spec);
    let listener = bind(&sock).unwrap();
    let pool = new_pool(dir.path());
    pool.scope.spawn_named("test pool", serve(pool.clone(), listener));

    let mut chats = Vec::new();
    for n in 0..3 {
        let s = UnixStream::connect(&sock).await.unwrap();
        let (r, mut w) = s.into_split();
        let mut r = BufReader::new(r).lines();
        w.write_all(format!("{key}\n").as_bytes()).await.unwrap();
        w.write_all(
            format!("{{\"jsonrpc\":\"2.0\",\"id\":\"l{n}\",\"method\":\"subscriptions/listen\",\"params\":{{}}}}\n")
                .as_bytes(),
        )
        .await
        .unwrap();
        let ack = read(&mut r).await;
        assert_eq!(ack["method"], "notifications/subscriptions/acknowledged");
        assert_eq!(
            ack["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"],
            format!("l{n}")
        );
        chats.push((r, w));
    }
    // No chat got another's ack: the next line each reads is its own answer.
    for (n, (r, w)) in chats.iter_mut().enumerate() {
        w.write_all(
            format!("{{\"jsonrpc\":\"2.0\",\"id\":\"t{n}\",\"method\":\"tools/list\"}}\n")
                .as_bytes(),
        )
        .await
        .unwrap();
        let v = read(r).await;
        assert_eq!(v["id"], format!("t{n}"), "{v}");
    }
    pool.scope.token().cancel();
}

/// A harness writes `initialize` the moment it starts the shim: that first request reaches the
/// server and is answered under the harness's own id, never failed as "starting again".
#[test]
fn shim_answers_an_initialize_written_before_it_connects() {
    use std::io::{BufRead, Write};
    let rt =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("p.sock");
    let spec = Spec {
        command: "python3".into(),
        args: vec!["-c".into(), SERVER.into(), "early".into()],
        ..Default::default()
    };
    let key = spec.key();
    specs().lock().unwrap().insert(key.clone(), spec);
    let pool = rt.block_on(async {
        let listener = bind(&sock).unwrap();
        let pool = new_pool(dir.path());
        pool.scope.spawn_named("test pool", serve(pool.clone(), listener));
        pool
    });
    let (mut harness_in, shim_in) = std::os::unix::net::UnixStream::pair().unwrap();
    let (shim_out, harness_out) = std::os::unix::net::UnixStream::pair().unwrap();
    harness_in
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{}}\n")
        .unwrap();
    harness_out.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    std::thread::scope(|threads| {
        let shim_run =
            threads.spawn(|| shim(&sock, &key, std::io::BufReader::new(shim_in), shim_out));
        let mut answers = std::io::BufReader::new(&harness_out);
        let mut l = String::new();
        answers.read_line(&mut l).unwrap();
        let v: Value = serde_json::from_str(&l).unwrap();
        assert_eq!(v["id"], 0, "{v}");
        assert_eq!(v["result"]["m"], "initialize", "the server's answer, not an error: {v}");
        drop(harness_in);
        shim_run.join().unwrap().unwrap();
    });
    pool.scope.token().cancel();
}
