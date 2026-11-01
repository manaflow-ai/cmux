use std::io::{Read, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use super::*;

const VM: &str = "vm_abcdefghij0123456789";
const TOKEN: &str = "fs-identity-token-0123456789";
const CREDENTIAL: &str = "cmux-credential-secret";
const T0: u64 = 1_800_000_000_000;

/// One request the fake saw.
#[derive(Debug, Clone)]
struct Seen {
    line: String,
    headers: String,
    body: Vec<u8>,
}

impl Seen {
    fn is_mint(&self) -> bool {
        self.line.starts_with(&format!("POST /v1/cloud/machines/{VM}/client-session "))
    }
    fn is_exec_await(&self) -> bool {
        self.line.starts_with("POST /v5/vms/fsvm-1/exec-await ")
    }
    fn is_proxy(&self) -> bool {
        self.line.contains(&format!("/v1/cloud/machines/{VM}/fs/"))
            || self.line.starts_with(&format!("POST /v1/cloud/machines/{VM}/exec "))
    }
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }
}

type Reply = (u16, String);

/// A fake cmux API and Freestyle on one local port. `handler` answers each request.
fn fake(
    handler: impl Fn(&Seen) -> Reply + Send + Sync + 'static,
) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 65536];
            let (head, body) = loop {
                let n = stream.read(&mut chunk).unwrap_or(0);
                buffer.extend_from_slice(&chunk[..n]);
                if let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&buffer[..end]).to_string();
                    let length = head
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(|v| v.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if buffer.len() >= end + 4 + length || n == 0 {
                        break (head, buffer[end + 4..].to_vec());
                    }
                } else if n == 0 {
                    break (String::from_utf8_lossy(&buffer).to_string(), Vec::new());
                }
            };
            let (line, headers) =
                head.split_once("\r\n").map_or((head.clone(), String::new()), |(l, h)| {
                    (l.to_owned(), h.to_ascii_lowercase())
                });
            let request = Seen { line, headers, body };
            let (status, reply) = handler(&request);
            log.lock().unwrap().push(request);
            let _ = stream.write_all(
                format!("HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}", reply.len())
                    .as_bytes(),
            );
        }
    });
    (origin, seen)
}

fn minted(origin: &str) -> Reply {
    (200, json!({ "ok": true, "value": { "machine": VM, "vm_id": "fsvm-1", "linux_user": "cmux", "token": TOKEN, "expires_at": T0 + 900_000, "api_base_url": origin, "ssh": null } }).to_string())
}

/// Runs an exec-await request's command here with bash, as the machine would.
fn run_here(seen: &Seen) -> Reply {
    let body = seen.json();
    let command = body["command"].as_str().unwrap().to_owned();
    let stdin = body
        .get("stdin")
        .and_then(Value::as_str)
        .map(|s| BASE64.decode(s).unwrap())
        .unwrap_or_default();
    let mut child = std::process::Command::new("bash")
        .args(["-c", &command])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(&stdin).unwrap();
    let out = child.wait_with_output().unwrap();
    (200, json!({ "statusCode": out.status.code(), "stdout": String::from_utf8_lossy(&out.stdout), "stderr": String::from_utf8_lossy(&out.stderr) }).to_string())
}

fn python_here() -> bool {
    std::process::Command::new("python3").arg("-c").arg("pass").status().is_ok_and(|s| s.success())
}

fn request(origin: &str, cache: &std::path::Path, op: Op) -> Request {
    Request {
        api: origin.to_owned(),
        credential: CREDENTIAL.to_owned(),
        team: Some("team_x".into()),
        machine: VM.into(),
        op,
        path: Some("/home/cmux/notes.txt".into()),
        data_base64: None,
        mode: None,
        command: None,
        timeout_ms: None,
        cache_dir: Some(cache.to_owned()),
        route: RouteChoice::Auto,
        app_version: None,
    }
}

/// The production client (`http_client`): one built here without its rustls provider install panicked in
/// every test that runs alone in its process (nextest).
fn client() -> reqwest::Client {
    http_client().unwrap()
}

fn go(request: &Request, now: u64) -> (Route, Answer) {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(perform(&client(), request, move || now))
}

fn count(seen: &Arc<Mutex<Vec<Seen>>>, which: fn(&Seen) -> bool) -> usize {
    seen.lock().unwrap().iter().filter(|s| which(s)).count()
}

/// A stat answer from the machine, the same for every exec-await.
fn stat_reply() -> Reply {
    (200, json!({ "statusCode": 0, "stdout": "{\"path\":\"/home/cmux/notes.txt\",\"kind\":\"file\",\"size\":3,\"mode\":420,\"modifiedAt\":1}", "stderr": "" }).to_string())
}

fn proxy_reply() -> Reply {
    (200, json!({ "path": "/home/cmux/notes.txt", "kind": "file", "size": 3, "mode": 420, "modifiedAt": 1, "via": "proxy" }).to_string())
}

#[test]
fn mints_once_then_reuses_the_cached_session_with_only_the_identity_token() {
    let dir = tempfile::tempdir().unwrap();
    let origin_cell = Arc::new(Mutex::new(String::new()));
    let cell = Arc::clone(&origin_cell);
    let (origin, seen) =
        fake(move |s| if s.is_mint() { minted(&cell.lock().unwrap()) } else { stat_reply() });
    *origin_cell.lock().unwrap() = origin.clone();
    let req = request(&origin, dir.path(), Op::Stat);
    let (route, answer) = go(&req, T0);
    assert_eq!(route, Route::Direct);
    assert_eq!(answer.status, 200);
    assert_eq!(answer.body["kind"], "file");
    let (route, _) = go(&req, T0 + 60_000);
    assert_eq!(route, Route::Direct);
    assert_eq!(count(&seen, Seen::is_mint), 1, "the second call reuses the session");
    assert_eq!(count(&seen, Seen::is_exec_await), 2);
    let log = seen.lock().unwrap();
    let mint = log.iter().find(|s| s.is_mint()).unwrap();
    assert!(
        mint.headers.contains(&format!("authorization: bearer {CREDENTIAL}")),
        "{}",
        mint.headers
    );
    assert!(mint.headers.contains("x-cmux-team: team_x"));
    assert_eq!(mint.json(), json!({ "ttl_seconds": 900 }));
    for exec in log.iter().filter(|s| s.is_exec_await()) {
        assert!(exec.headers.contains(&format!("x-freestyle-identity-access-token: {TOKEN}")));
        assert!(
            !exec.headers.contains("authorization:"),
            "the cmux credential never goes to the provider"
        );
        assert_eq!(exec.json()["linuxUser"], "cmux");
    }
}

#[test]
fn renews_a_session_close_to_its_end_and_keeps_the_cache_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let cache_dir = dir.path().join("sessions");
    let cell = Arc::new(Mutex::new(String::new()));
    let c = Arc::clone(&cell);
    let (origin, seen) =
        fake(move |s| if s.is_mint() { minted(&c.lock().unwrap()) } else { stat_reply() });
    *cell.lock().unwrap() = origin.clone();
    let req = request(&origin, &cache_dir, Op::Stat);
    go(&req, T0);
    // Still more than the renew margin left: reused.
    go(&req, T0 + 900_000 - session::RENEW_MARGIN_MS - 1_000);
    assert_eq!(count(&seen, Seen::is_mint), 1);
    // Inside the margin: a new session before the call.
    go(&req, T0 + 900_000 - session::RENEW_MARGIN_MS + 1_000);
    assert_eq!(count(&seen, Seen::is_mint), 2);
    assert_eq!(std::fs::metadata(&cache_dir).unwrap().permissions().mode() & 0o777, 0o700);
    for entry in std::fs::read_dir(&cache_dir).unwrap() {
        let path = entry.unwrap().path();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(!path.display().to_string().contains(TOKEN));
    }
}

#[test]
fn the_cache_trusts_the_shorter_of_the_servers_expiry_and_its_own_clock() {
    assert_eq!(session::use_until(T0 + 900_000, T0), T0 + 900_000);
    // A server clock far ahead of this one: still at most the asked lifetime from now.
    assert_eq!(session::use_until(T0 + 9_000_000, T0), T0 + 900_000);
    let grant = Grant {
        vm_id: "v".into(),
        linux_user: "cmux".into(),
        token: "t".into(),
        api_base_url: "u".into(),
    };
    let entry = Entry::Session { grant: grant.clone(), use_until_ms: T0 + 900_000 };
    assert_eq!(session::decide(Some(&entry), T0), Use::Direct(grant));
    assert_eq!(session::decide(Some(&entry), T0 + 900_000 - session::RENEW_MARGIN_MS), Use::Mint);
    assert_eq!(session::decide(Some(&Entry::ProxyUntil { until_ms: T0 + 1 }), T0), Use::Proxy);
    assert_eq!(session::decide(Some(&Entry::ProxyUntil { until_ms: T0 }), T0), Use::Mint);
    assert_eq!(session::decide(None, T0), Use::Mint);
}

#[test]
fn a_refused_mint_takes_the_proxy_and_remembers_it_by_refusal() {
    for (status, code, held) in [
        (501, "cloud.provider.unsupported", true),
        (403, "auth.forbidden", true),
        (429, "cloud.rate_limited", true),
        (409, "cloud.machine.paused", false),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let (origin, seen) = fake(move |s| {
            if s.is_mint() {
                (
                    status,
                    json!({ "ok": false, "error": { "code": code, "message": "no" } }).to_string(),
                )
            } else {
                proxy_reply()
            }
        });
        let req = request(&origin, dir.path(), Op::Stat);
        let (route, answer) = go(&req, T0);
        assert_eq!((route, answer.status), (Route::Proxy, 200), "{status}");
        assert_eq!(answer.body["via"], "proxy");
        go(&req, T0 + 30_000);
        assert_eq!(count(&seen, Seen::is_mint), if held { 1 } else { 2 }, "{status}");
        assert_eq!(count(&seen, Seen::is_proxy), 2);
        assert_eq!(count(&seen, Seen::is_exec_await), 0);
        let proxied = seen.lock().unwrap().iter().find(|s| s.is_proxy()).cloned().unwrap();
        assert!(
            proxied.line.starts_with(&format!(
                "GET /v1/cloud/machines/{VM}/fs/stat?path=%2Fhome%2Fcmux%2Fnotes.txt "
            )),
            "{}",
            proxied.line
        );
        assert!(proxied.headers.contains(&format!("authorization: bearer {CREDENTIAL}")));
    }
    // The ten-minute hold ends: the next call mints again.
    let dir = tempfile::tempdir().unwrap();
    let (origin, seen) = fake(|s| if s.is_mint() { (501, "{}".into()) } else { proxy_reply() });
    let req = request(&origin, dir.path(), Op::Stat);
    go(&req, T0);
    go(&req, T0 + 10 * 60 * 1000 + 1);
    assert_eq!(count(&seen, Seen::is_mint), 2);
}

#[test]
fn a_cached_token_the_provider_refuses_is_minted_again_and_a_fresh_refused_one_takes_the_proxy() {
    let dir = tempfile::tempdir().unwrap();
    let cell = Arc::new(Mutex::new(String::new()));
    let c = Arc::clone(&cell);
    let refuse_next = Arc::new(Mutex::new(false));
    let r = Arc::clone(&refuse_next);
    let (origin, seen) = fake(move |s| {
        if s.is_mint() {
            minted(&c.lock().unwrap())
        } else if s.is_exec_await() && std::mem::take(&mut *r.lock().unwrap()) {
            (403, "{}".into())
        } else if s.is_exec_await() {
            stat_reply()
        } else {
            proxy_reply()
        }
    });
    *cell.lock().unwrap() = origin.clone();
    let req = request(&origin, dir.path(), Op::Stat);
    go(&req, T0);
    *refuse_next.lock().unwrap() = true;
    let (route, _) = go(&req, T0 + 1_000);
    assert_eq!(route, Route::Direct, "re-minted and ran directly");
    assert_eq!(count(&seen, Seen::is_mint), 2);

    // Every exec-await refused: the fresh token's refusal takes the proxy, and the proxy is held.
    let dir = tempfile::tempdir().unwrap();
    let cell = Arc::new(Mutex::new(String::new()));
    let c = Arc::clone(&cell);
    let (origin, seen) = fake(move |s| {
        if s.is_mint() {
            minted(&c.lock().unwrap())
        } else if s.is_exec_await() {
            (401, "{}".into())
        } else {
            proxy_reply()
        }
    });
    *cell.lock().unwrap() = origin.clone();
    let req = request(&origin, dir.path(), Op::Stat);
    let (route, answer) = go(&req, T0);
    assert_eq!((route, answer.body["via"].as_str()), (Route::Proxy, Some("proxy")));
    go(&req, T0 + 1_000);
    assert_eq!(count(&seen, Seen::is_mint), 1);
    assert_eq!(count(&seen, Seen::is_exec_await), 1);
}

#[test]
fn what_needs_root_or_is_not_for_the_direct_route_goes_to_the_proxy() {
    // The program says the work user may not do it.
    let dir = tempfile::tempdir().unwrap();
    let cell = Arc::new(Mutex::new(String::new()));
    let c = Arc::clone(&cell);
    let (origin, seen) = fake(move |s| {
        if s.is_mint() {
            minted(&c.lock().unwrap())
        } else if s.is_exec_await() {
            (
                200,
                json!({ "statusCode": direct::NEEDS_ROOT, "stdout": "", "stderr": "" }).to_string(),
            )
        } else {
            proxy_reply()
        }
    });
    *cell.lock().unwrap() = origin.clone();
    let (route, _) = go(&request(&origin, dir.path(), Op::Stat), T0);
    assert_eq!(route, Route::Proxy);
    assert_eq!(count(&seen, Seen::is_exec_await), 1);

    // Requests the proxy answers itself, with no mint: a bad path, a remove of the root, a classic
    // machine id, bad base64, an empty command, or a request that asks for the proxy.
    let (origin, seen) = fake(|_| proxy_reply());
    let base = request(&origin, dir.path(), Op::Stat);
    let mut cases = Vec::new();
    for path in ["relative", "/a/../b", " /padded", "/nul\0"] {
        cases.push(Request { path: Some(path.into()), ..base.clone() });
    }
    cases.push(Request { op: Op::Remove, path: Some("/./".into()), ..base.clone() });
    cases.push(Request { machine: "vm-57a93abc9c2f4af3ba5c11845d991912".into(), ..base.clone() });
    cases.push(Request { op: Op::Write, data_base64: Some("not base64!".into()), ..base.clone() });
    cases.push(Request {
        op: Op::Write,
        data_base64: Some(String::new()),
        mode: Some(0o10000),
        ..base.clone()
    });
    cases.push(Request { op: Op::Exec, command: Some("  ".into()), ..base.clone() });
    cases.push(Request { route: RouteChoice::Proxy, ..base });
    for case in &cases {
        assert_eq!(go(case, T0).0, Route::Proxy, "{case:?}");
    }
    assert_eq!(count(&seen, Seen::is_mint), 0);
    assert_eq!(count(&seen, Seen::is_exec_await), 0);
    // Each went to the cmux API's own route (the classic id to its own machine path).
    assert_eq!(count(&seen, |s| s.line.contains(" /v1/cloud/machines/")), cases.len());
}

#[test]
fn an_exec_the_provider_may_have_run_is_not_run_again_through_the_proxy() {
    let dir = tempfile::tempdir().unwrap();
    let cell = Arc::new(Mutex::new(String::new()));
    let c = Arc::clone(&cell);
    let (origin, seen) = fake(move |s| {
        if s.is_mint() {
            minted(&c.lock().unwrap())
        } else if s.is_exec_await() {
            (500, "{}".into())
        } else {
            proxy_reply()
        }
    });
    *cell.lock().unwrap() = origin.clone();
    let req = Request {
        command: Some("touch /tmp/once".into()),
        timeout_ms: Some(999_999),
        ..request(&origin, dir.path(), Op::Exec)
    };
    let (route, answer) = go(&req, T0);
    assert_eq!(
        (route, answer.status, answer.code.as_deref()),
        (Route::Direct, 502, Some("vm_unavailable"))
    );
    assert_eq!(count(&seen, Seen::is_proxy), 0);
    let log = seen.lock().unwrap();
    let exec = log.iter().find(|s| s.is_exec_await()).unwrap().json();
    assert_eq!(exec["timeoutMs"], 300_000, "capped at the provider's inline limit");
    assert!(exec["command"].as_str().unwrap().ends_with(" 1048576 'touch /tmp/once'"));
}

#[test]
fn proxy_refusals_pass_through_as_the_route_gave_them_without_the_credential() {
    let dir = tempfile::tempdir().unwrap();
    let (origin, _seen) = fake(|_| {
        (
            402,
            json!({ "error": "upgrade", "upgradeRequired": true, "echo": CREDENTIAL }).to_string(),
        )
    });
    let req = Request { route: RouteChoice::Proxy, ..request(&origin, dir.path(), Op::Read) };
    let (route, answer) = go(&req, T0);
    let answer = scrub(answer, CREDENTIAL);
    assert_eq!((route, answer.status), (Route::Proxy, 402));
    assert_eq!(answer.body["upgradeRequired"], true);
    assert!(!answer.body.to_string().contains(CREDENTIAL));
}

#[test]
fn the_cache_key_follows_the_person_across_refreshed_tokens() {
    let jwt = |sub: &str, n: u32| {
        let claims = URL_SAFE.encode(json!({ "sub": sub, "iat": n }).to_string());
        format!("e30.{claims}.sig{n}")
    };
    use base64::engine::general_purpose::URL_SAFE_NO_PAD as URL_SAFE;
    assert_eq!(session::subject(&jwt("user-1", 1)), session::subject(&jwt("user-1", 2)));
    assert_ne!(session::subject(&jwt("user-1", 1)), session::subject(&jwt("user-2", 1)));
    assert!(session::subject("opaque").starts_with("credential:"));
    assert!(!session::subject("opaque").contains("opaque"));
}

/// The file program end to end: the fake provider runs each exec here with bash and python3.
#[test]
fn files_round_trip_through_the_program_small_staged_and_ranged() {
    if !python_here() {
        eprintln!("skipped: no python3");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("machine");
    std::fs::create_dir(&root).unwrap();
    let cell = Arc::new(Mutex::new(String::new()));
    let c = Arc::clone(&cell);
    let (origin, seen) = fake(move |s| {
        if s.is_mint() {
            minted(&c.lock().unwrap())
        } else if s.is_exec_await() {
            run_here(s)
        } else {
            (599, "{}".into())
        }
    });
    *cell.lock().unwrap() = origin.clone();
    let cache = dir.path().join("cache");
    let at = |p: &str| format!("{}{p}", root.display());
    let base = request(&origin, &cache, Op::Stat);

    // Small (one exec), staged (over 1 MiB: chunks then a checked rename) and a ranged read back.
    for size in [1_000_000_usize, direct::STDIN_MAX * 5 + 17] {
        let data: Vec<u8> = (0..size).map(|i| (i * 31 % 251) as u8).collect();
        let path = at(&format!("/f{size}.bin"));
        let write = Request {
            op: Op::Write,
            path: Some(path.clone()),
            data_base64: Some(BASE64.encode(&data)),
            mode: Some(0o640),
            ..base.clone()
        };
        let (route, answer) = go(&write, T0);
        assert_eq!((route, answer.status), (Route::Direct, 200), "{answer:?}");
        assert_eq!(std::fs::read(&path).unwrap(), data);
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o640);
        let (_, answer) =
            go(&Request { op: Op::Read, path: Some(path.clone()), ..base.clone() }, T0);
        assert_eq!(answer.status, 200);
        assert_eq!(answer.body["size"], size);
        assert_eq!(BASE64.decode(answer.body["dataBase64"].as_str().unwrap()).unwrap(), data);
    }
    let leftovers: Vec<_> = std::fs::read_dir(&root)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with(".cmux-write-"))
        .collect();
    assert!(leftovers.is_empty(), "no staging file is left behind");

    // A new file without a mode is 0600; an existing one keeps its mode.
    let path = at("/new.txt");
    go(
        &Request {
            op: Op::Write,
            path: Some(path.clone()),
            data_base64: Some(BASE64.encode("a")),
            ..base.clone()
        },
        T0,
    );
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    go(
        &Request {
            op: Op::Write,
            path: Some(path.clone()),
            data_base64: Some(BASE64.encode("b")),
            ..base.clone()
        },
        T0,
    );
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o644);

    let (_, answer) = go(&Request { op: Op::Mkdir, path: Some(at("/d/e")), ..base.clone() }, T0);
    assert_eq!(answer.status, 200);
    let (_, answer) = go(&Request { op: Op::Dir, path: Some(at("")), ..base.clone() }, T0);
    let names: Vec<&str> = answer.body["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"d") && names.contains(&"new.txt"), "{names:?}");
    let (_, answer) = go(&Request { op: Op::Stat, path: Some(at("/d")), ..base.clone() }, T0);
    assert_eq!(answer.body["kind"], "directory");
    let (_, answer) = go(&Request { op: Op::Remove, path: Some(at("/d")), ..base.clone() }, T0);
    assert_eq!(answer.status, 200);
    let (route, answer) = go(&Request { op: Op::Read, path: Some(at("/d/e")), ..base.clone() }, T0);
    assert_eq!(
        (route, answer.status, answer.code.as_deref()),
        (Route::Direct, 404, Some("vm_file_not_found"))
    );
    let (_, answer) = go(&Request { op: Op::Read, path: Some(at("")), ..base.clone() }, T0);
    assert_eq!((answer.status, answer.code.as_deref()), (400, Some("vm_invalid_path")));

    let (route, answer) = go(
        &Request {
            op: Op::Exec,
            command: Some("printf hi; printf oops >&2; exit 3".into()),
            ..base
        },
        T0,
    );
    assert_eq!(route, Route::Direct);
    assert_eq!(answer.body, json!({ "exitCode": 3, "stdout": "hi", "stderr": "oops" }));
    assert_eq!(count(&seen, Seen::is_mint), 1, "one session for every call");
}

#[test]
fn a_path_the_work_user_may_not_write_goes_to_the_proxy() {
    if !python_here()
        || std::process::Command::new("id")
            .arg("-u")
            .output()
            .is_ok_and(|o| o.stdout.starts_with(b"0\n"))
    {
        eprintln!("skipped: no python3, or running as root");
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let locked = dir.path().join("locked");
    std::fs::create_dir(&locked).unwrap();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o500)).unwrap();
    let cell = Arc::new(Mutex::new(String::new()));
    let c = Arc::clone(&cell);
    let (origin, seen) = fake(move |s| {
        if s.is_mint() {
            minted(&c.lock().unwrap())
        } else if s.is_exec_await() {
            run_here(s)
        } else {
            proxy_reply()
        }
    });
    *cell.lock().unwrap() = origin.clone();
    let req = Request {
        op: Op::Write,
        path: Some(format!("{}/x", locked.display())),
        data_base64: Some(BASE64.encode("x")),
        ..request(&origin, &dir.path().join("cache"), Op::Write)
    };
    let (route, _) = go(&req, T0);
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(route, Route::Proxy);
    let log = seen.lock().unwrap();
    let proxied = log.iter().find(|s| s.is_proxy()).unwrap();
    assert!(proxied.line.starts_with(&format!("POST /v1/cloud/machines/{VM}/fs/write ")));
    assert_eq!(proxied.json()["dataBase64"], BASE64.encode("x"));
}

#[test]
fn a_change_the_machine_may_have_made_is_not_made_again_through_the_proxy() {
    for (op, proxied) in [
        (Op::Write, false),
        (Op::Mkdir, false),
        (Op::Remove, false),
        (Op::Stat, true),
        (Op::Dir, true),
        (Op::Read, true),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let cell = Arc::new(Mutex::new(String::new()));
        let c = Arc::clone(&cell);
        let (origin, seen) = fake(move |s| {
            if s.is_mint() {
                minted(&c.lock().unwrap())
            } else if s.is_exec_await() {
                (500, "{}".into())
            } else {
                proxy_reply()
            }
        });
        *cell.lock().unwrap() = origin.clone();
        let req =
            Request { data_base64: Some(BASE64.encode("x")), ..request(&origin, dir.path(), op) };
        let (route, answer) = go(&req, T0);
        if proxied {
            assert_eq!((route, answer.status), (Route::Proxy, 200), "{op:?}");
        } else {
            assert_eq!(
                (route, answer.status, answer.code.as_deref()),
                (Route::Direct, 502, Some("vm_unavailable")),
                "{op:?}"
            );
            assert_eq!(count(&seen, Seen::is_proxy), 0, "{op:?}");
        }
    }
}

/// The fake machine replaces the file once, between a read's first and second chunk.
#[test]
fn a_read_never_mixes_two_versions_of_the_file() {
    if !python_here() {
        eprintln!("skipped: no python3");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("big.bin");
    let old: Vec<u8> = vec![1; direct::READ_CHUNK as usize + 17];
    let new: Vec<u8> = vec![2; direct::READ_CHUNK as usize + 5];
    std::fs::write(&path, &old).unwrap();
    let cell = Arc::new(Mutex::new(String::new()));
    let c = Arc::clone(&cell);
    let reads = Arc::new(Mutex::new(0_usize));
    let r = Arc::clone(&reads);
    let (target, replacement) = (path.clone(), new.clone());
    let (origin, _seen) = fake(move |s| {
        if s.is_mint() {
            return minted(&c.lock().unwrap());
        }
        if s.json()["command"].as_str().is_some_and(|c| c.contains(" read ")) {
            let mut n = r.lock().unwrap();
            *n += 1;
            if *n == 2 {
                let staged = target.with_extension("next");
                std::fs::write(&staged, &replacement).unwrap();
                std::fs::rename(&staged, &target).unwrap();
            }
        }
        run_here(s)
    });
    *cell.lock().unwrap() = origin.clone();
    let req = Request {
        path: Some(path.display().to_string()),
        ..request(&origin, &dir.path().join("cache"), Op::Read)
    };
    let (route, answer) = go(&req, T0);
    assert_eq!((route, answer.status), (Route::Direct, 200));
    let got = BASE64.decode(answer.body["dataBase64"].as_str().unwrap()).unwrap();
    assert_eq!(got, new, "read again from the start: all of the new file, none of the old");
    assert!(*reads.lock().unwrap() >= 3);
}
