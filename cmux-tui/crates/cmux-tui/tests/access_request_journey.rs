//! File requests from a Cloud machine's agents (Move to Cloud, slice 6), end
//! to end with real processes: a headless cmux-tui daemon shaped like a
//! personal Cloud VM keeps the requests (`access-request-v1`), an agent
//! there asks with `cmux link access request`, and this Mac's
//! `cmux link access triage` / `answer` decide and push through the
//! machine's `fs-v1`, as the app does over its machine link. The Mac side
//! is the CLI with its own home and state folder.
//!
//! Linux only: a Cloud host is a Linux machine (`cloud_fs::is_cloud_host`).
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

use journey_support::*;
use serde_json::{Value, json};

const CHAT: &str = "chat-moved-from-the-mac";
const OTHER_CHAT: &str = "chat-made-on-the-machine";

/// The person's Mac: a home with files and a state folder.
struct Mac {
    home: PathBuf,
    state: PathBuf,
}

impl Mac {
    fn new(root: &Path) -> Self {
        let home = root.join("mac-home");
        for dir in ["projects/designs", "notes", "private", ".ssh"] {
            fs::create_dir_all(home.join(dir)).unwrap();
        }
        fs::write(home.join("projects/designs/a.txt"), "granted file\n").unwrap();
        fs::write(home.join("notes/todo.txt"), "asked once\n").unwrap();
        fs::write(home.join("notes/plan.txt"), "asked always\n").unwrap();
        fs::write(home.join("private/deny.txt"), "never sent\n").unwrap();
        fs::write(home.join("private/elsewhere.txt"), "led elsewhere\n").unwrap();
        std::os::unix::fs::symlink("../private/elsewhere.txt", home.join("notes/shortcut.txt"))
            .unwrap();
        fs::write(home.join(".ssh/id_ed25519"), "fake-private-key\n").unwrap();
        Self { home, state: root.join("mac-state") }
    }

    /// `cmux link access ARGS` on this Mac: whether it exited 0 and its line.
    fn access(&self, args: &[&str]) -> (bool, Value) {
        run_json(
            Command::new(bin())
                .env("HOME", &self.home)
                .env("CMUX_TUI_STATE_DIR", &self.state)
                .env_remove("CMUX_AGENT_SESSION")
                .env_remove("CMUX_TUI_SOCKET")
                .args(["link", "access"])
                .args(args),
        )
    }
}

/// An agent on the machine asking for `path`: the running CLI.
fn ask(vm: &Machine, session: &str, path: &Path, timeout: &str) -> Child {
    vm.command()
        .env("CMUX_AGENT_SESSION", session)
        .args(["link", "access", "request", "--socket"])
        .arg(&vm.socket)
        .args(["--timeout", timeout, "--reason", "to read it"])
        .arg(path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

/// What an agent's request CLI printed: whether it exited 0, and its line.
fn answered(child: Child) -> (bool, Value) {
    let output = child.wait_with_output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().last().unwrap_or_default();
    let answer = serde_json::from_str(line).unwrap_or_else(|_| {
        panic!("no JSON line: {stdout}{}", String::from_utf8_lossy(&output.stderr))
    });
    (output.status.success(), answer)
}

fn pending(vm: &Machine) -> Vec<Value> {
    let listed = vm.rpc(json!({"id": 1, "cmd": "access-request-list"}));
    assert_eq!(listed["ok"], true, "{listed}");
    listed["data"]["requests"].as_array().cloned().unwrap_or_default()
}

/// The pending request of this Mac's chat for `path` (the other chat asks
/// for one of the same files).
fn id_for(requests: &[Value], path: &Path) -> String {
    let path = path.to_str().unwrap();
    requests.iter().find(|r| r["path"] == path && r["session"] == CHAT).unwrap()["request_id"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[test]
fn an_access_request_outside_any_grant_waits_for_the_person_and_one_inside_is_answered() {
    let root = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(root.path()).unwrap();
    let mac = Mac::new(&root);
    let home = mac.home.clone();
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-access-request-journey".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let socket = vm.socket.to_str().unwrap();
    let work = vm.home().join("work");
    let work = work.to_str().unwrap();

    // The chat already has one folder of the Mac, read-only.
    let designs = home.join("projects/designs");
    let (ok, granted) = mac.access(&[
        "grant",
        "--socket",
        socket,
        "--machine",
        "vm-1",
        "--session",
        CHAT,
        "--remote-root",
        work,
        "--mode",
        "read",
        designs.to_str().unwrap(),
    ]);
    assert!(ok, "{granted}");

    let in_grant = ask(&vm, CHAT, &designs.join("a.txt"), "60");
    let once = ask(&vm, CHAT, &home.join("notes/todo.txt"), "60");
    let always = ask(&vm, CHAT, &home.join("notes/plan.txt"), "60");
    let denied = ask(&vm, CHAT, &home.join("private/deny.txt"), "60");
    let key = ask(&vm, CHAT, &home.join(".ssh/id_ed25519"), "60");
    let climbing = ask(&vm, CHAT, &home.join("notes/../.ssh/id_ed25519"), "60");
    let shortcut = ask(&vm, CHAT, &home.join("notes/shortcut.txt"), "60");
    // A chat this Mac did not move: it gives up waiting on its own.
    let other = ask(&vm, OTHER_CHAT, &home.join("notes/todo.txt"), "5");
    let requests = wait_until(30, "eight requests on the machine", || {
        let requests = pending(&vm);
        (requests.len() == 8).then_some(requests)
    });
    let other_id = requests.iter().find(|r| r["session"] == OTHER_CHAT).unwrap()["request_id"]
        .as_str()
        .unwrap()
        .to_owned();

    // The Mac answers what the grant and the rules decide; the rest waits
    // for the person (the inline card), and another chat's request is left.
    let (ok, triaged) =
        mac.access(&["triage", "--socket", socket, "--machine", "vm-1", "--session", CHAT]);
    assert!(ok, "{triaged}");
    let outcomes: Vec<(String, String)> = triaged["answered"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| {
            (a["path"].as_str().unwrap().to_owned(), a["outcome"].as_str().unwrap().to_owned())
        })
        .collect();
    assert_eq!(outcomes.len(), 3, "{triaged}");
    assert!(outcomes.contains(&(designs.join("a.txt").display().to_string(), "delivered".into())));
    assert!(
        outcomes.contains(&(home.join(".ssh/id_ed25519").display().to_string(), "denied".into()))
    );
    // `..` is judged as written: it climbs into ~/.ssh.
    let climbing_path = home.join("notes/../.ssh/id_ed25519").display().to_string();
    assert!(outcomes.contains(&(climbing_path, "denied".into())), "{triaged}");
    let asked: Vec<&str> =
        triaged["ask"].as_array().unwrap().iter().map(|a| a["path"].as_str().unwrap()).collect();
    assert_eq!(asked.len(), 4, "{triaged}");
    let notes = home.join("notes");
    let plan_ask = triaged["ask"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["path"] == json!(home.join("notes/plan.txt").to_str().unwrap()))
        .unwrap()
        .clone();
    assert_eq!(plan_ask["always_folder"], json!(notes.to_str().unwrap()), "{triaged}");
    // The card shows where a symlink leads, not only the name asked for.
    let elsewhere = home.join("private/elsewhere.txt");
    let shortcut_ask = triaged["ask"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["path"] == json!(home.join("notes/shortcut.txt").to_str().unwrap()))
        .unwrap()
        .clone();
    assert_eq!(shortcut_ask["target"], json!(elsewhere.to_str().unwrap()), "{triaged}");
    assert_eq!(shortcut_ask["always_folder"], json!(home.join("private").to_str().unwrap()));

    let (ok, answer) = answered(in_grant);
    assert!(ok, "{answer}");
    let at = PathBuf::from(answer["path"].as_str().unwrap());
    assert!(at.starts_with(work), "{answer}");
    assert_eq!(fs::read_to_string(&at).unwrap(), "granted file\n");
    let (ok, answer) = answered(key);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "access_denied", "{answer}");
    let (ok, answer) = answered(climbing);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "access_denied", "{answer}");

    let todo = home.join("notes/todo.txt");
    let plan = home.join("notes/plan.txt");
    let deny = home.join("private/deny.txt");
    let requests = pending(&vm);
    let shortcut_path = home.join("notes/shortcut.txt");
    let pending_ids: Vec<String> =
        [&todo, &plan, &deny, &shortcut_path].iter().map(|path| id_for(&requests, path)).collect();
    let answer_args = |request: &str, how: &str, shown: &[&Path]| -> (bool, Value) {
        let mut args = vec![
            "answer",
            "--socket",
            socket,
            "--machine",
            "vm-1",
            "--session",
            CHAT,
            "--request",
            request,
            "--remote-root",
            work,
            how,
        ];
        // What the card showed: the path, where it leads, the folder.
        let flags = ["", "--target", "--folder"];
        for (flag, path) in flags.iter().zip(shown) {
            if !flag.is_empty() {
                args.push(flag);
            }
            args.push(path.to_str().unwrap());
        }
        mac.access(&args)
    };
    // The person's answer names the path they saw; another path is refused.
    let (ok, changed) = answer_args(&pending_ids[2], "--allow", &[&todo, &todo]);
    assert!(!ok, "{changed}");
    assert_eq!(changed["error_code"], "request_changed", "{changed}");
    // An answer that names where a symlink led before is refused too.
    let (ok, changed) = answer_args(&pending_ids[3], "--allow", &[&shortcut_path, &shortcut_path]);
    assert!(!ok, "{changed}");
    assert_eq!(changed["error_code"], "request_changed", "{changed}");
    let (ok, allowed) = answer_args(&pending_ids[3], "--allow", &[&shortcut_path, &elsewhere]);
    assert!(ok, "{allowed}");
    let (ok, allowed) = answer_args(&pending_ids[0], "--allow", &[&todo, &todo]);
    assert!(ok, "{allowed}");
    let (ok, wrong_folder) = answer_args(&pending_ids[1], "--always", &[&plan, &plan, &home]);
    assert!(!ok, "{wrong_folder}");
    assert_eq!(wrong_folder["error_code"], "request_changed", "{wrong_folder}");
    let (ok, always_answer) = answer_args(&pending_ids[1], "--always", &[&plan, &plan, &notes]);
    assert!(ok, "{always_answer}");
    let (ok, deny_answer) = answer_args(&pending_ids[2], "--deny", &[]);
    assert!(ok, "{deny_answer}");

    let (ok, answer) = answered(once);
    assert!(ok, "{answer}");
    let at = PathBuf::from(answer["path"].as_str().unwrap());
    assert!(at.starts_with(format!("{work}/local/requests/")), "{answer}");
    assert_eq!(fs::read_to_string(&at).unwrap(), "asked once\n");
    let (ok, answer) = answered(shortcut);
    assert!(ok, "{answer}");
    assert_eq!(fs::read_to_string(answer["path"].as_str().unwrap()).unwrap(), "led elsewhere\n");
    let (ok, answer) = answered(always);
    assert!(ok, "{answer}");
    assert_eq!(fs::read_to_string(answer["path"].as_str().unwrap()).unwrap(), "asked always\n");
    let (ok, answer) = answered(denied);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "access_denied", "{answer}");
    let (ok, grants) = mac.access(&["grants", "--machine", "vm-1", "--session", CHAT]);
    assert!(ok, "{grants}");
    let folders: Vec<&str> = grants["grants"]
        .as_array()
        .unwrap()
        .iter()
        .map(|g| g["folder"].as_str().unwrap())
        .collect();
    assert!(folders.contains(&notes.to_str().unwrap()), "{grants}");

    // The other chat's request was never answered.
    let (ok, answer) = answered(other);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "access_pending", "{answer}");
    let status = vm.rpc(json!({"id": 2, "cmd": "access-request-status", "request_id": other_id}));
    assert_eq!(status["data"]["state"], "pending", "{status}");
    // Nothing the person did not share reached the machine.
    for (path, bytes) in files_below(&vm.home()) {
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("fake-private-key"), "{} holds the key", path.display());
        assert!(!text.contains("never sent"), "{} holds a denied file", path.display());
    }
}

/// A fake secret: no real credential is ever used.
const FAKE_SECRET: &str = "fake-npm-token-0123456789";

/// An agent on the machine asking for the secret `name`.
fn ask_secret(vm: &Machine, session: &str, name: &str) -> Child {
    vm.command()
        .env("CMUX_AGENT_SESSION", session)
        .args(["link", "access", "request", "--socket"])
        .arg(&vm.socket)
        .args(["--timeout", "60", "--reason", "to publish", "--secret", name])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

#[test]
fn a_secret_access_request_waits_for_the_person_and_its_value_is_read_once() {
    let root = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(root.path()).unwrap();
    let mac = Mac::new(&root);
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-secret-request-journey".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let socket = vm.socket.to_str().unwrap();

    let shared = ask_secret(&vm, CHAT, "NPM_TOKEN");
    let refused = ask_secret(&vm, CHAT, "AWS_SECRET_ACCESS_KEY");
    let requests = wait_until(30, "two secret requests on the machine", || {
        let requests = pending(&vm);
        (requests.len() == 2).then_some(requests)
    });
    let id_named = |name: &str| {
        requests.iter().find(|r| r["name"] == name).unwrap()["request_id"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let (shared_id, refused_id) = (id_named("NPM_TOKEN"), id_named("AWS_SECRET_ACCESS_KEY"));

    // Nothing answers a secret but the person.
    let (ok, triaged) =
        mac.access(&["triage", "--socket", socket, "--machine", "vm-1", "--session", CHAT]);
    assert!(ok, "{triaged}");
    assert_eq!(triaged["answered"], json!([]), "{triaged}");
    let asked = triaged["ask"].as_array().unwrap();
    assert_eq!(asked.len(), 2, "{triaged}");
    assert!(asked.iter().all(|a| a["kind"] == "secret" && a["path"].is_null()), "{triaged}");

    let answer = |request: &str, args: &[&str], input: &str| -> (bool, Value, String) {
        let mut child = Command::new(bin())
            .env("HOME", &mac.home)
            .env("CMUX_TUI_STATE_DIR", &mac.state)
            .env_remove("CMUX_AGENT_SESSION")
            .env_remove("CMUX_TUI_SOCKET")
            .args(["link", "access", "answer", "--socket", socket, "--machine", "vm-1"])
            .args(["--session", CHAT, "--request", request])
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write as _;
        child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        let output = child.wait_with_output().unwrap();
        let printed = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = serde_json::from_str(stdout.lines().last().unwrap_or_default())
            .unwrap_or_else(|_| panic!("no JSON line: {printed}"));
        (output.status.success(), line, printed)
    };
    // The machine takes no file answer for a secret request.
    let wrong = vm.rpc(json!({"id": 2, "cmd": "access-request-answer", "request_id": shared_id,
                              "outcome": "delivered", "path": "/root/work/x"}));
    assert_eq!(wrong["error_code"], "access_request.bad_request", "{wrong}");
    // The value comes on stdin, for the name the person saw, and once.
    let (ok, changed, _) = answer(&shared_id, &["--share-secret", "GITHUB_TOKEN"], FAKE_SECRET);
    assert!(!ok, "{changed}");
    assert_eq!(changed["error_code"], "request_changed", "{changed}");
    let (ok, as_file, _) =
        answer(&shared_id, &["--allow", mac.home.join("notes/todo.txt").to_str().unwrap()], "");
    assert!(!ok, "{as_file}");
    assert_eq!(as_file["error_code"], "request_changed", "{as_file}");
    let (ok, shared_answer, printed) =
        answer(&shared_id, &["--share-secret", "NPM_TOKEN"], FAKE_SECRET);
    assert!(ok, "{shared_answer}");
    assert!(!printed.contains(FAKE_SECRET), "the Mac printed the secret: {printed}");
    let (ok, refused_answer, _) = answer(&refused_id, &["--deny"], "");
    assert!(ok, "{refused_answer}");

    let (ok, got) = answered(shared);
    assert!(ok, "{got}");
    assert_eq!(got["name"], "NPM_TOKEN", "{got}");
    assert_eq!(got["value"], FAKE_SECRET, "{got}");
    let (ok, got) = answered(refused);
    assert!(!ok, "{got}");
    assert_eq!(got["error_code"], "access_denied", "{got}");
    // The machine kept it for the first read only.
    let status = vm.rpc(json!({"id": 3, "cmd": "access-request-status", "request_id": shared_id}));
    assert_eq!(status["data"]["state"], "delivered", "{status}");
    assert_eq!(status["data"]["taken"], true, "{status}");
    assert!(!status.to_string().contains(FAKE_SECRET), "{status}");
    // A secret answer of a file request is refused by the machine.
    let file = ask(&vm, CHAT, &mac.home.join("notes/todo.txt"), "5");
    let file_id = wait_until(30, "a file request", || {
        pending(&vm).first().and_then(|r| r["request_id"].as_str().map(str::to_owned))
    });
    let wrong = vm.rpc(json!({"id": 4, "cmd": "access-request-answer", "request_id": file_id,
                              "outcome": "delivered", "value": FAKE_SECRET}));
    assert_eq!(wrong["error_code"], "access_request.bad_request", "{wrong}");
    let _ = answered(file);
    // Nowhere on disk on either side: homes, state folders, daemon logs.
    for (path, bytes) in files_below(&root) {
        assert!(
            !String::from_utf8_lossy(&bytes).contains(FAKE_SECRET),
            "{} holds the secret",
            path.display()
        );
    }
}

#[test]
fn a_daemon_that_is_not_a_cloud_machine_takes_no_access_requests() {
    let root = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(root.path()).unwrap();
    let mac = Machine::start(&root, "mac", Vec::new());
    let refused = mac.rpc(json!({"id": 1, "cmd": "access-request", "kind": "file",
                                 "path": "/etc/hosts", "session": CHAT}));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], "access_request.unavailable", "{refused}");
}

fn files_below(dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut found = Vec::new();
    let Ok(entries) = fs::read_dir(dir) else { return found };
    for entry in entries {
        let path = entry.unwrap().path();
        let Ok(meta) = fs::symlink_metadata(&path) else { continue };
        if meta.is_dir() {
            found.extend(files_below(&path));
        } else if meta.is_file() {
            found.push((path.clone(), fs::read(&path).unwrap_or_default()));
        }
    }
    found
}
