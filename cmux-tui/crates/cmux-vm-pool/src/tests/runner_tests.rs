//! `cmux vm runner`: request shapes, the credential reads and the stdin-only JIT config, against a mocked HTTP
//! server (no real call is made).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::freestyle::{self, Freestyle, base64};
use crate::runner::{self, Fleet, Jit, Pacing, Request, RunnerVm, Secret, Size};
use crate::runner_cli;

#[derive(Clone, Debug)]
struct Seen {
    method: String,
    path: String,
    auth: String,
    body: String,
}

type Handler = Arc<dyn Fn(&Seen) -> (u16, String) + Send + Sync>;

async fn serve(handler: Handler) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let (handler, log) = (handler.clone(), log.clone());
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 8192];
                let (head_end, want) = loop {
                    let n = sock.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..i]).to_lowercase();
                        let len = head
                            .lines()
                            .find_map(|l| {
                                l.strip_prefix("content-length:")
                                    .and_then(|v| v.trim().parse::<usize>().ok())
                            })
                            .unwrap_or(0);
                        break (i + 4, len);
                    }
                };
                while buf.len() < head_end + want {
                    let n = sock.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
                let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
                let mut first = head.lines().next().unwrap_or("").split(' ');
                let auth = head
                    .lines()
                    .find(|l| l.to_lowercase().starts_with("authorization:"))
                    .map(|l| l.split_once(':').unwrap().1.trim().to_owned())
                    .unwrap_or_default();
                let seen = Seen {
                    method: first.next().unwrap_or("").to_owned(),
                    path: first.next().unwrap_or("").to_owned(),
                    auth,
                    body: String::from_utf8_lossy(&buf[head_end..]).into_owned(),
                };
                let (status, body) = handler(&seen);
                log.lock().unwrap().push(seen);
                let reply = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = sock.write_all(reply.as_bytes()).await;
            });
        }
    });
    (base, seen)
}

fn client() -> reqwest::Client {
    crate::http::client().unwrap()
}

#[test]
fn create_body_is_the_hq_shape_with_no_auto_delete() {
    let body = runner::create_body("fsr-1-abcdef", "cmux-freestyle-linux-x64", "leo");
    assert_eq!(body["idleTimeoutSeconds"], -1);
    assert_eq!(body["automaticRestart"], false);
    assert_eq!(body["displayName"], "fsr-1-abcdef");
    assert_eq!(
        body["firewall"],
        json!({"rules": [{"action": "allow", "source": {}, "destination": {"public": true}}]})
    );
    assert_eq!(
        body["metadata"],
        json!({"purpose": "freestyle-runners", "fsr_runner": "fsr-1-abcdef", "fsr_want": "cmux-freestyle-linux-x64", "fsr_owner": "leo"})
    );
    let obj = body.as_object().unwrap();
    assert!(!obj.contains_key("autoDeleteSeconds") && !obj.contains_key("ttlSeconds"));
    assert_eq!(
        Size::default().resize_body(),
        json!({"cpu": 8, "memory": 16384, "storage": 153_600})
    );
}

#[test]
fn jit_body_has_the_four_fields() {
    let labels = vec!["cmux-freestyle-linux-x64".to_owned()];
    assert_eq!(
        runner::jit_body("fsr-1-abcdef", 7, &labels),
        json!({"name": "fsr-1-abcdef", "runner_group_id": 7, "labels": labels, "work_folder": "/home/runner/work"})
    );
}

#[tokio::test]
async fn jit_request_looks_the_group_up_by_name_and_posts_the_config_request() {
    let handler: Handler = Arc::new(|r| {
        if r.path.starts_with("/orgs/acme/actions/runner-groups") {
            (
                200,
                json!({"runner_groups": [{"id": 1, "name": "other"}, {"id": 42, "name": "grp"}]})
                    .to_string(),
            )
        } else if r.path == "/orgs/acme/actions/runners/generate-jitconfig" {
            (
                201,
                json!({"runner": {"id": 99}, "encoded_jit_config": "JIT-SECRET-VALUE"}).to_string(),
            )
        } else {
            (404, "{}".to_owned())
        }
    });
    let (base, seen) = serve(handler).await;
    let jit = Jit::new(&base, Secret::new("ghp_tok".to_owned()), "acme");
    let c = client();
    let gid = jit.group_id(&c, "grp").await.unwrap();
    assert_eq!(gid, 42);
    assert!(jit.group_id(&c, "missing").await.unwrap_err().contains("no runner group `missing`"));
    let labels = vec!["a".to_owned(), "b".to_owned()];
    let minted = jit.mint(&c, "fsr-2-000000", gid, &labels).await.unwrap();
    assert_eq!(minted.runner_id, 99);
    assert_eq!(minted.config.expose(), "JIT-SECRET-VALUE");
    assert_eq!(format!("{:?}{}", minted.config, minted.config), "Secret(<redacted>)<redacted>");
    let seen = seen.lock().unwrap();
    let post = seen.iter().find(|s| s.method == "POST").unwrap();
    assert_eq!(post.auth, "Bearer ghp_tok");
    let body: Value = serde_json::from_str(&post.body).unwrap();
    assert_eq!(
        body,
        json!({"name": "fsr-2-000000", "runner_group_id": 42, "labels": ["a", "b"], "work_folder": "/home/runner/work"})
    );
}

fn env_of(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let map: Vec<(String, String)> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    move |name: &str| map.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())
}

#[test]
fn key_read_prefers_the_env_then_the_file_and_never_shows_the_key() {
    let dir = std::env::temp_dir().join(format!("cmux-runner-key-{}", std::process::id()));
    let cfg = dir.join(".config").join("freestyle");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::write(cfg.join("api-key"), "file-key-SECRET\n").unwrap();
    let home = dir.to_str().unwrap();

    let from_env = runner_cli::freestyle_key(&env_of(&[
        ("FREESTYLE_API_KEY", "env-key-SECRET"),
        ("HOME", home),
    ]))
    .unwrap();
    assert_eq!(from_env.expose(), "env-key-SECRET");
    let from_file = runner_cli::freestyle_key(&env_of(&[("HOME", home)])).unwrap();
    assert_eq!(from_file.expose(), "file-key-SECRET");
    // Neither Debug nor Display shows it, nor does the client's Debug.
    let shown = format!("{from_file:?} {from_file}");
    assert!(!shown.contains("SECRET"));
    let fs = Freestyle::new("http://x", from_file.expose().to_owned(), "p");
    assert!(!format!("{fs:?}").contains("SECRET"));
    // A missing file names the path and the error kind, not contents.
    std::fs::remove_file(cfg.join("api-key")).unwrap();
    let missing = runner_cli::freestyle_key(&env_of(&[("HOME", home)])).unwrap_err();
    assert!(missing.contains("api-key") && !missing.contains("SECRET"));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn github_token_prefers_the_env_then_gh() {
    let none = || None;
    assert_eq!(
        runner_cli::github_token(&env_of(&[("GITHUB_TOKEN", "a"), ("GH_TOKEN", "b")]), &none)
            .unwrap()
            .expose(),
        "a"
    );
    assert_eq!(
        runner_cli::github_token(&env_of(&[]), &|| Some("from-gh\n".to_owned())).unwrap().expose(),
        "from-gh"
    );
    assert!(runner_cli::github_token(&env_of(&[]), &none).is_err());
}

#[test]
fn base64_matches_the_standard_alphabet() {
    assert_eq!(base64(b""), "");
    assert_eq!(base64(b"f"), "Zg==");
    assert_eq!(base64(b"fo"), "Zm8=");
    assert_eq!(base64(b"foo"), "Zm9v");
    assert_eq!(base64(b"hello world"), "aGVsbG8gd29ybGQ=");
}

fn vm(id: &str, state: &str, owner: Option<&str>, cpu: u64, want: &str) -> RunnerVm {
    let mut meta = json!({"purpose": "freestyle-runners", "fsr_runner": format!("fsr-{id}"), "fsr_want": want});
    if let Some(o) = owner {
        meta["fsr_owner"] = json!(o);
    }
    runner::parse_runner_vm(&json!({
        "id": id, "state": state, "metadata": meta,
        "resources": {"cpu": cpu, "memory": cpu * 2048, "storage": 153_600},
    }))
    .unwrap()
}

#[test]
fn only_parked_vms_of_the_same_owner_are_taken_and_no_owner_means_hq() {
    let vms = vec![
        vm("run", "running", Some("leo"), 8, "w"),
        vm("other", "stopped", Some("zed"), 8, "w"),
        vm("hq", "stopped", None, 8, "w"),
        vm("small", "stopped", Some("leo"), 8, "x"),
        vm("exact", "stopped", Some("leo"), 8, "w"),
        vm("big", "stopped", Some("leo"), 16, "w"),
    ];
    let ids = |owner: &str| {
        runner::rank_parked(&vms, owner, "w", Size { cpu: 8 })
            .iter()
            .map(|v| v.id.clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(ids("leo"), ["exact", "small", "big"]);
    assert_eq!(ids(runner::HQ_OWNER), ["hq"]);
    assert!(ids("nobody").is_empty());
    assert!(
        runner::parse_runner_vm(&json!({"id": "x", "metadata": {"purpose": "other"}})).is_none()
    );
}

#[test]
fn saved_stop_refuses_at_3200_and_when_unread() {
    assert!(runner::saved_room(Some(3199)).is_ok());
    assert!(runner::saved_room(Some(3200)).unwrap_err().contains("3200"));
    assert!(runner::saved_room(None).is_err());
}

#[test]
fn runner_pin_matches_hq_and_the_guest_has_the_verbs() {
    assert_eq!(runner::RUNNER_VERSION, "2.338.2");
    assert_eq!(runner::RUNNER_SHA256.len(), 64);
    for verb in ["prepare)", "prepare-bg)", "prepare-result)", "start)", "start-direct)", "reset)"]
    {
        assert!(runner::GUEST_SCRIPT.contains(&format!("  {verb} ")), "guest lacks {verb}");
    }
    // The JIT config never reaches a file: start-direct has no write of $jit.
    let direct = runner::GUEST_SCRIPT
        .split("start_direct() {")
        .nth(1)
        .unwrap()
        .split("\n}\n")
        .next()
        .unwrap();
    assert!(!direct.contains("> \"$state/jit\"") && !direct.contains("printf '%s' \"$jit\""));
    assert!(direct.contains("ACTIONS_RUNNER_INPUT_JITCONFIG=\"$jit\" nohup"));
}

fn fleet_handler(vms: Value, total: u64) -> Handler {
    Arc::new(move |r| {
        let path = r.path.as_str();
        if r.method == "GET" && path.starts_with("/v5/vms?limit=1&") {
            return (200, json!({"vms": [], "totalCount": total}).to_string());
        }
        if r.method == "GET" && path.starts_with("/v5/vms?") {
            return (200, json!({"vms": vms}).to_string());
        }
        if r.method == "GET" && path.starts_with("/v5/vms/") {
            return (200, json!({"id": "vm-new", "state": "running", "metadata": {"purpose": "freestyle-runners"},
                "resources": {"cpu": 8, "memory": 16384, "storage": 153_600}}).to_string());
        }
        if r.method == "POST" && path == "/v5/vms" {
            return (200, json!({"id": "vm-new"}).to_string());
        }
        if path.ends_with("/exec-await") {
            return (200, json!({"statusCode": 0, "stdout": "", "stderr": ""}).to_string());
        }
        (200, "{}".to_owned())
    })
}

fn fast() -> Pacing {
    Pacing { boot_poll: Duration::from_millis(1), prepare_poll: Duration::from_millis(1) }
}

#[tokio::test]
async fn a_new_vm_is_made_when_none_is_parked_and_the_jit_config_travels_on_stdin_only() {
    let (base, seen) = serve(fleet_handler(json!([]), 10)).await;
    let fs = Freestyle::new(&base, "fs-key".to_owned(), runner::PURPOSE);
    let c = client();
    let log = |_: &str| {};
    let fleet = Fleet { client: &c, fs: &fs, pacing: fast(), log: &log };
    let req =
        Request { owner: "leo".to_owned(), labels: vec!["l".to_owned()], size: Size::default() };
    let prepared = fleet.make_or_resume(&req, &|_| true).await.unwrap();
    assert!(!prepared.reused && prepared.vm_id == "vm-new" && prepared.name.starts_with("fsr-"));
    let jit = Secret::new("ZZ-JIT-CONFIG-ZZ".to_owned());
    fleet.start_runner("vm-new", &prepared.name, &jit).await.unwrap();

    let seen = seen.lock().unwrap();
    let wire = base64(jit.expose().as_bytes());
    let carrying: Vec<&Seen> = seen
        .iter()
        .filter(|s| s.body.contains(&wire) || s.path.contains("JIT") || s.body.contains("ZZ-JIT"))
        .collect();
    assert_eq!(carrying.len(), 1, "the config appears in exactly one request");
    let body: Value = serde_json::from_str(&carrying[0].body).unwrap();
    assert!(carrying[0].path.ends_with("/exec-await"));
    assert_eq!(body["stdin"], wire.as_str());
    assert!(!body["command"].as_str().unwrap().contains("ZZ-JIT"));
    assert!(
        body["command"]
            .as_str()
            .unwrap()
            .starts_with("bash /root/runner-guest.sh start-direct fsr-")
    );
    // The create carried the Freestyle key as the bearer and the hq body; the guest was prepared.
    let create = seen.iter().find(|s| s.method == "POST" && s.path == "/v5/vms").unwrap();
    assert_eq!(create.auth, "Bearer fs-key");
    let made: Value = serde_json::from_str(&create.body).unwrap();
    assert_eq!(made["metadata"]["fsr_owner"], "leo");
    assert!(seen.iter().any(|s| s.body.contains("prepare-bg 2.338.2")));
    assert!(seen.iter().any(|s| s.path == "/v5/vms/vm-new/resize"));
    assert!(seen.iter().all(|s| s.method != "DELETE"));
}

#[tokio::test]
async fn a_parked_vm_of_the_owner_is_resumed_in_hq_order_and_nothing_is_created() {
    let rows = json!([{"id": "vm-old", "state": "stopped",
        "metadata": {"purpose": "freestyle-runners", "fsr_runner": "fsr-old", "fsr_want": "l", "fsr_owner": "leo"},
        "resources": {"cpu": 8, "memory": 16384, "storage": 153_600}}]);
    let (base, seen) = serve(fleet_handler(rows, 10)).await;
    let fs = Freestyle::new(&base, "k".to_owned(), runner::PURPOSE);
    let c = client();
    let log = |_: &str| {};
    let fleet = Fleet { client: &c, fs: &fs, pacing: fast(), log: &log };
    let req =
        Request { owner: "leo".to_owned(), labels: vec!["l".to_owned()], size: Size::default() };
    let p = fleet.make_or_resume(&req, &|_| true).await.unwrap();
    assert!(p.reused && p.vm_id == "vm-old" && p.previous_runner.as_deref() == Some("fsr-old"));
    let seen = seen.lock().unwrap();
    assert!(!seen.iter().any(|s| s.method == "POST" && s.path == "/v5/vms"), "no create");
    let at = |pred: &dyn Fn(&Seen) -> bool| seen.iter().position(pred).expect("step missing");
    let rename =
        at(&|s| s.method == "PATCH" && s.path == "/v5/vms/vm-old" && s.body.contains("fsr_owner"));
    let start = at(&|s| s.path == "/v5/vms/vm-old/start");
    let reset = at(&|s| s.body.contains("runner-guest.sh reset"));
    let prepare = at(&|s| s.body.contains("prepare-bg"));
    assert!(
        rename < start && start < reset && reset < prepare,
        "rename, start, reset, prepare in order"
    );
}

#[tokio::test]
async fn a_failed_resume_powers_off_and_falls_back_to_a_create_below_the_stop() {
    let rows = json!([{"id": "vm-old", "state": "stopped",
        "metadata": {"purpose": "freestyle-runners", "fsr_runner": "fsr-old", "fsr_want": "l", "fsr_owner": "leo"},
        "resources": {"cpu": 8, "memory": 16384, "storage": 153_600}}]);
    let inner = fleet_handler(rows, 10);
    // The old VM's reset fails.
    let handler: Handler = Arc::new(move |r| {
        if r.path == "/v5/vms/vm-old/exec-await" {
            let body: Value = serde_json::from_str(&r.body).unwrap();
            if body["command"].as_str().unwrap().ends_with("reset") {
                return (200, json!({"statusCode": 1, "stdout": "", "stderr": "boom"}).to_string());
            }
        }
        inner(r)
    });
    let (base, seen) = serve(handler).await;
    let fs = Freestyle::new(&base, "k".to_owned(), runner::PURPOSE);
    let c = client();
    let log = |_: &str| {};
    let fleet = Fleet { client: &c, fs: &fs, pacing: fast(), log: &log };
    let req =
        Request { owner: "leo".to_owned(), labels: vec!["l".to_owned()], size: Size::default() };
    let p = fleet.make_or_resume(&req, &|_| true).await.unwrap();
    assert!(!p.reused && p.vm_id == "vm-new");
    let seen = seen.lock().unwrap();
    assert!(seen.iter().any(|s| s.path == "/v5/vms/vm-old/exec-await"
        && s.body.contains("systemctl --no-block poweroff")));
}

#[tokio::test]
async fn no_vm_is_made_at_the_saved_stop() {
    let (base, seen) = serve(fleet_handler(json!([]), 3200)).await;
    let fs = Freestyle::new(&base, "k".to_owned(), runner::PURPOSE);
    let c = client();
    let log = |_: &str| {};
    let fleet = Fleet { client: &c, fs: &fs, pacing: fast(), log: &log };
    let req =
        Request { owner: "leo".to_owned(), labels: vec!["l".to_owned()], size: Size::default() };
    let e = fleet.make_or_resume(&req, &|_| true).await.unwrap_err();
    assert!(e.contains("3200"), "{e}");
    assert!(!seen.lock().unwrap().iter().any(|s| s.method == "POST"));
}

#[test]
fn exec_body_puts_stdin_in_base64_and_runs_as_root() {
    let body = freestyle::exec_body("cat", Some(b"foo"), 5000);
    assert_eq!(
        body,
        json!({"command": "cat", "linuxUser": "root", "timeoutMs": 5000, "stdin": "Zm9v"})
    );
    assert!(freestyle::exec_body("true", None, 1000).get("stdin").is_none());
}

#[test]
fn job_record_parses_the_hook_file() {
    let rec = runner::parse_job_record(
        "repository a/b\nrun_id 12\nrun_attempt 2\njob build\nworkflow CI\n",
    )
    .unwrap();
    assert_eq!(
        (rec.repository.as_str(), rec.run_id.as_str(), rec.run_attempt.as_str()),
        ("a/b", "12", "2")
    );
    assert!(runner::parse_job_record("repository \nrun_id \n").is_none());
}

#[test]
fn a_new_vm_beside_a_parked_one_says_why_it_was_skipped() {
    let vms = vec![
        vm("other", "stopped", Some("zed"), 8, "w"),
        vm("hq", "stopped", None, 8, "w"),
        vm("busy", "running", Some("leo"), 8, "w"),
        vm("napping", "paused", Some("leo"), 8, "w"),
    ];
    let why = runner::no_resume_reason(&vms, "leo");
    assert!(why.starts_with("no parked runner VM of leo to resume; making one"), "{why}");
    assert!(why.contains("paused with a GitHub record: napping (paused, owner leo)"), "{why}");
    assert!(why.contains("yours, not parked: busy (running, owner leo)"), "{why}");
    assert!(why.contains("parked, another owner's: other (stopped, owner zed)"), "{why}");
    assert!(why.contains(&format!("hq (stopped, owner {})", runner::HQ_OWNER)), "{why}");
    assert_eq!(
        runner::no_resume_reason(&[], "leo"),
        "no parked runner VM of leo to resume; making one"
    );
}
