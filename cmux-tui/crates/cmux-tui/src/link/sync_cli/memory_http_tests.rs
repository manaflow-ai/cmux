//! `HttpHead` against a fake `AgentHome` service on loopback (axum), shaped
//! like cmux-platform's `agent-home/AgentHome.ts`: the person's token sees
//! and accepts everything; a machine's shows its capability, reads the
//! user-wide files and its own project's, proposes memory only and is
//! refused acceptance; follow off bumps the generation and drops the head.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use axum::body::Bytes;
use axum::http::{HeaderMap, Method as AxMethod, StatusCode as AxStatus, Uri};
use axum::response::{IntoResponse, Response};
use base64::Engine as _;
use serde_json::{Value, json};

use super::super::{Ctx, Head, RecordStore, pull, push, sha256_hex};
use super::*;

const PERSON: &str = "person-token";
const MACHINE: &str = "machine-token";
const CAPABILITY: &str = "ahc_test-capability-0123456789";
const PROJECT: &str = "local:-home-leo-proj";
const MEMORY: &str = ".claude/projects/-home-leo-proj/memory/MEMORY.md";

#[derive(Default)]
struct State {
    generation: u64,
    revision: u64,
    follow: bool,
    entries: BTreeMap<(String, String), String>,
    blobs: BTreeMap<String, Vec<u8>>,
    proposals: BTreeMap<String, (u64, Vec<Value>)>,
    acceptances: BTreeMap<String, String>,
    grants: BTreeMap<String, String>,
    serial: u64,
}

type Shared = Arc<Mutex<State>>;

struct Fake {
    origin: String,
    state: Shared,
    _thread: std::thread::JoinHandle<()>,
}

impl Fake {
    fn start() -> Fake {
        let state: Shared =
            Arc::new(Mutex::new(State { generation: 1, follow: true, ..State::default() }));
        let (tx, rx) = std::sync::mpsc::channel();
        let served = state.clone();
        let thread = std::thread::spawn(move || {
            let runtime =
                tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            runtime.block_on(async move {
                let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
                tx.send(listener.local_addr().unwrap()).unwrap();
                let router = axum::Router::new().fallback(
                    move |method: AxMethod, uri: Uri, headers: HeaderMap, body: Bytes| {
                        let state = served.clone();
                        async move { answer(&state, &method, uri.path(), &headers, &body) }
                    },
                );
                let _ = axum::serve(listener, router).await;
            });
        });
        let addr = rx.recv().unwrap();
        Fake { origin: format!("http://{addr}"), state, _thread: thread }
    }

    fn person(&self) -> HttpHead {
        HttpHead::new(&self.origin, PERSON, None).unwrap()
    }

    fn machine(&self) -> HttpHead {
        HttpHead::new(&self.origin, MACHINE, Some(CAPABILITY)).unwrap()
    }

    /// The person turns it off: a new generation, no head, no tokens.
    fn revoke(&self) {
        let mut state = self.state.lock().unwrap();
        state.generation += 1;
        state.follow = false;
        state.entries.clear();
        state.proposals.clear();
        state.grants.clear();
    }

    fn entry(&self, project: &str, path: &str) -> Option<Vec<u8>> {
        let state = self.state.lock().unwrap();
        let sha = state.entries.get(&(project.to_string(), path.to_string()))?;
        state.blobs.get(sha).cloned()
    }
}

fn refuse(status: u16, code: &str) -> Response {
    (AxStatus::from_u16(status).unwrap(), axum::Json(json!({"code": code, "message": code})))
        .into_response()
}

fn ok(status: u16, body: Value) -> Response {
    (AxStatus::from_u16(status).unwrap(), axum::Json(body)).into_response()
}

fn answer(
    state: &Shared,
    method: &AxMethod,
    path: &str,
    headers: &HeaderMap,
    body: &[u8],
) -> Response {
    let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok()).unwrap_or_default();
    let person = match header("authorization") {
        value if value == format!("Bearer {PERSON}") => true,
        value if value == format!("Bearer {MACHINE}") => false,
        _ => return refuse(401, "agent_home.unauthorized"),
    };
    if !person && header("x-agent-home-capability") != CAPABILITY {
        return refuse(403, "agent_home.capability_required");
    }
    let body: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    let mut s = state.lock().unwrap();
    let rest = path.strip_prefix("/v1/agent-home").unwrap_or("/missing");
    let parts: Vec<&str> = rest.split('/').filter(|part| !part.is_empty()).collect();
    match (method.as_str(), parts.as_slice()) {
        ("GET", []) => {
            let entries: Vec<Value> = s
                .entries
                .iter()
                .filter(|((project, _), _)| person || project.is_empty() || project == PROJECT)
                .map(|((project, path), sha)| json!({"project": project, "path": path, "sha256": sha}))
                .collect();
            let revision = if s.follow { s.revision } else { 0 };
            ok(
                200,
                json!({"follow": s.follow, "generation": s.generation, "revision": revision, "entries": entries}),
            )
        }
        ("POST", ["proposals"]) => {
            if !s.follow {
                return refuse(409, "agent_home.off");
            }
            if body["generation"].as_u64() != Some(s.generation) {
                return refuse(409, "agent_home.stale_generation");
            }
            let changes = body["changes"].as_array().cloned().unwrap_or_default();
            if changes.is_empty() {
                return refuse(400, "agent_home.bad_request");
            }
            for change in &changes {
                let project = change["project"].as_str().unwrap_or_default();
                let path = change["path"].as_str().unwrap_or_default();
                if !super::service_takes(project, path) {
                    return refuse(422, "agent_home.not_allowed");
                }
                if !person && project.is_empty() {
                    return refuse(403, "agent_home.instructions_from_machine");
                }
                if !person && project != PROJECT {
                    return refuse(403, "agent_home.outside_capability");
                }
                if let Some(bytes) = change["bytes"].as_str() {
                    let bytes = base64::engine::general_purpose::STANDARD.decode(bytes).unwrap();
                    assert_eq!(change["sha256"].as_str(), Some(sha256_hex(&bytes).as_str()));
                    s.blobs.insert(sha256_hex(&bytes), bytes);
                }
            }
            s.serial += 1;
            let id = format!("ahp_{:032x}", s.serial);
            let base = body["base"].as_u64().unwrap_or_default();
            s.proposals.insert(id.clone(), (base, changes));
            ok(201, json!({"id": id, "hash": "h", "generation": s.generation, "base": base}))
        }
        ("POST", ["proposals", id, "acceptance"]) => {
            if !person {
                return refuse(403, "agent_home.person_only");
            }
            if !s.proposals.contains_key(*id) {
                return refuse(404, "agent_home.not_found");
            }
            let token = format!("aha_{id}");
            s.acceptances.insert(token.clone(), (*id).to_string());
            ok(201, json!({"token": token, "proposal": id}))
        }
        ("POST", ["accept"]) => {
            if !person {
                return refuse(403, "agent_home.person_only");
            }
            let id = body["proposal"].as_str().unwrap_or_default().to_string();
            let token = body["token"].as_str().unwrap_or_default();
            if s.acceptances.remove(token).as_deref() != Some(id.as_str()) {
                return refuse(403, "agent_home.bad_acceptance");
            }
            if body["revision"].as_u64().is_some_and(|revision| revision != s.revision) {
                return refuse(409, "agent_home.revision_moved");
            }
            let Some((_, changes)) = s.proposals.remove(&id) else {
                return refuse(404, "agent_home.not_found");
            };
            for change in changes {
                let key = (
                    change["project"].as_str().unwrap_or_default().to_string(),
                    change["path"].as_str().unwrap_or_default().to_string(),
                );
                if change["op"] == "delete" {
                    s.entries.remove(&key);
                } else {
                    s.entries
                        .insert(key, change["sha256"].as_str().unwrap_or_default().to_string());
                }
            }
            s.revision += 1;
            ok(200, json!({"kind": "ok", "revision": s.revision, "generation": s.generation}))
        }
        ("POST", ["grants"]) => {
            if !s.follow {
                return refuse(409, "agent_home.off");
            }
            s.serial += 1;
            let token = format!("ahg_{:032x}", s.serial);
            let project = if person { "*" } else { PROJECT };
            s.grants.insert(token.clone(), project.to_string());
            ok(201, json!({"token": token, "generation": s.generation}))
        }
        ("GET", ["blobs", sha]) => {
            let Some(project) = s.grants.get(header("x-agent-home-grant")).cloned() else {
                return refuse(403, "agent_home.grant_required");
            };
            let readable = s.entries.iter().any(|((p, _), held)| {
                held == sha && (project == "*" || p.is_empty() || *p == project)
            });
            match s.blobs.get(*sha).filter(|_| readable) {
                Some(bytes) => (AxStatus::OK, bytes.clone()).into_response(),
                None => refuse(404, "agent_home.not_found"),
            }
        }
        _ => refuse(404, "route.not_found"),
    }
}

struct Device {
    _tmp: tempfile::TempDir,
    home: PathBuf,
    record: PathBuf,
}

fn device() -> Device {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    Device { record: tmp.path().join("record"), home, _tmp: tmp }
}

fn ctx<'a>(device: &Device, head: &'a dyn Head, machine: bool) -> Ctx<'a> {
    Ctx {
        home: device.home.clone(),
        user: None,
        record: RecordStore { root: device.record.clone() },
        head,
        device: if machine { "vm".into() } else { "mac".into() },
        machine,
        race: None,
    }
}

fn put(home: &Path, relative: &str, text: &str) {
    let path = home.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn read(home: &Path, relative: &str) -> Option<String> {
    std::fs::read_to_string(home.join(relative)).ok()
}

#[test]
fn home_paths_map_to_the_service_and_back() {
    for (key, project, path) in [
        (".claude/CLAUDE.md", "", "claude/CLAUDE.md"),
        (".codex/AGENTS.md", "", "codex/AGENTS.md"),
        (".gemini/GEMINI.md", "", "gemini/GEMINI.md"),
        (".claude/agents/reviewer.md", "", "claude/agents/reviewer.md"),
        (".claude/commands/ship/it.md", "", "claude/commands/ship/it.md"),
        (".claude/skills/a/SKILL.md", "", "claude/skills/a/SKILL.md"),
        (".codex/prompts/fix.md", "", "codex/prompts/fix.md"),
        (MEMORY, PROJECT, "claude/memory/MEMORY.md"),
    ] {
        assert_eq!(to_service(key), Some((project.to_string(), path.to_string())), "{key}");
        assert_eq!(from_service(project, path).as_deref(), Some(key), "{project} {path}");
    }
    // The service takes top-level agent notes only, and a slug that is a
    // project id; a git-remote project id has no home path yet.
    assert_eq!(to_service(".claude/agents/deep/x.md"), None);
    assert_eq!(to_service(".claude/agents/notes.txt"), None);
    assert_eq!(to_service(".claude/projects/short/memory/a.md"), None);
    assert_eq!(from_service("github.com/o/r", "claude/memory/a.md"), None);
    assert_eq!(from_service("", "cmux/context.md"), None);
    assert_eq!(from_service("", "claude/settings.json"), None);
}

#[test]
fn origins_are_https_or_loopback_http() {
    assert_eq!(
        origin_of("https://platform-edge.cmux.dev/").unwrap(),
        "https://platform-edge.cmux.dev"
    );
    assert_eq!(origin_of("http://127.0.0.1:9").unwrap(), "http://127.0.0.1:9");
    assert!(origin_of("http://platform-edge.cmux.dev").is_err());
    assert!(origin_of("https://h/v1/agent-home").is_err());
    assert!(origin_of("https://user@h").is_err());
    assert!(is_url("https://h") && !is_url("/srv/head"));
}

/// Leo pushes from the Mac, the push accepts itself, and a Cloud machine's
/// pull writes the user CLAUDE.md (and its project's memory).
#[test]
fn a_person_push_accepts_itself_and_a_machine_pulls_it() {
    let fake = Fake::start();
    let mac = device();
    put(&mac.home, ".claude/CLAUDE.md", "codeword: blue-heron\n");
    put(&mac.home, MEMORY, "- the probe remembers\n");
    put(&mac.home, ".claude/settings.json", "{\"never\": true}\n");
    let person = fake.person();
    let out = push(&ctx(&mac, &person, false)).unwrap();
    assert_eq!(out.accepted_revision, Some(1));
    assert_eq!(out.revision, Some(1));
    assert_eq!(out.proposed, vec![".claude/CLAUDE.md".to_string(), MEMORY.to_string()]);
    assert_eq!(fake.entry("", "claude/CLAUDE.md").as_deref(), Some(&b"codeword: blue-heron\n"[..]));
    assert_eq!(
        fake.entry(PROJECT, "claude/memory/MEMORY.md").as_deref(),
        Some(&b"- the probe remembers\n"[..])
    );
    let json = serde_json::to_value(&out).unwrap();
    assert_eq!(json["accepted_revision"], 1);

    // Pushing again proposes nothing: the service's 0o644 is not a change.
    let again = push(&ctx(&mac, &person, false)).unwrap();
    assert_eq!(again.proposal, None);
    assert_eq!(again.accepted_revision, None);

    let vm = device();
    let machine = fake.machine();
    let pulled = pull(&ctx(&vm, &machine, true)).unwrap();
    assert_eq!(pulled.revision, Some(1));
    assert_eq!(read(&vm.home, ".claude/CLAUDE.md").as_deref(), Some("codeword: blue-heron\n"));
    assert_eq!(read(&vm.home, MEMORY).as_deref(), Some("- the probe remembers\n"));
    assert_eq!(read(&vm.home, ".claude/settings.json"), None);
}

/// A machine proposes its memory, never its instructions, and is refused
/// when it tries to accept; its push never accepts.
#[test]
fn a_machine_is_refused_acceptance() {
    let fake = Fake::start();
    let mac = device();
    put(&mac.home, ".claude/CLAUDE.md", "codeword: blue-heron\n");
    push(&ctx(&mac, &fake.person(), false)).unwrap();

    let vm = device();
    let machine = fake.machine();
    pull(&ctx(&vm, &machine, true)).unwrap();
    put(&vm.home, MEMORY, "- learned on the machine\n");
    put(&vm.home, ".claude/CLAUDE.md", "an agent rewrote this\n");
    let out = push(&ctx(&vm, &machine, true)).unwrap();
    assert_eq!(out.proposed, vec![MEMORY.to_string()]);
    assert_eq!(out.accepted_revision, None);
    let id = out.proposal.unwrap();
    let error = machine.accept(&id, 1).unwrap_err().to_string();
    assert!(error.contains("agent_home.person_only"), "{error}");
    assert_eq!(fake.state.lock().unwrap().revision, 1);
    assert_eq!(fake.entry(PROJECT, "claude/memory/MEMORY.md"), None);
    // The person's own device can accept it.
    assert_eq!(fake.person().accept(&id, 1).unwrap(), 2);
}

/// The person turns it off (a generation bump): the machine's next pull
/// deletes every carried file and puts back the original it replaced.
#[test]
fn a_generation_bump_deletes_the_carried_files() {
    let fake = Fake::start();
    let mac = device();
    put(&mac.home, ".claude/CLAUDE.md", "codeword: blue-heron\n");
    put(&mac.home, MEMORY, "- the probe remembers\n");
    push(&ctx(&mac, &fake.person(), false)).unwrap();

    let vm = device();
    put(&vm.home, ".claude/CLAUDE.md", "the machine's own\n");
    let machine = fake.machine();
    pull(&ctx(&vm, &machine, true)).unwrap();
    assert_eq!(read(&vm.home, ".claude/CLAUDE.md").as_deref(), Some("codeword: blue-heron\n"));

    fake.revoke();
    let out = pull(&ctx(&vm, &machine, true)).unwrap();
    assert_eq!(out.generation, 2);
    assert_eq!(out.deleted, vec![MEMORY.to_string()]);
    assert_eq!(out.restored, vec![".claude/CLAUDE.md".to_string()]);
    assert_eq!(read(&vm.home, MEMORY), None);
    assert_eq!(read(&vm.home, ".claude/CLAUDE.md").as_deref(), Some("the machine's own\n"));
}

/// Gate site `cmux_tui::link::sync_cli::memory_http` (tests/egress_seeded.json):
/// a push sends the carried files and nothing else from the home, so secrets
/// in credential and settings files beside them reach no request.
#[test]
fn seeded_secrets_beside_the_carried_files_never_reach_the_wire() {
    cmux_egress::capture::install().unwrap();
    let mac = device();
    put(&mac.home, ".claude/CLAUDE.md", "carried instructions\n");
    put(&mac.home, ".claude/.credentials.json", "{\"token\": \"SEEDclaudeCredential0123\"}");
    put(&mac.home, ".claude/settings.json", "{\"env\": {\"K\": \"SEEDclaudeSettings0123\"}}");
    put(&mac.home, ".codex/auth.json", "{\"key\": \"SEEDcodexAuth0123\"}");
    put(&mac.home, ".claude/projects/-home-leo-proj/memory/.env", "K=SEEDprojectEnv0123\n");
    put(&mac.home, ".claude/skills/a/secret.txt", "SEEDskillSecret0123\n");
    let host = "cmux-platform-staging.debussy.workers.dev";
    let head = HttpHead::new(&format!("https://{host}"), "seed-person-token", None).unwrap();
    // The capture server answers `200 {}`: the head reads empty, and the
    // proposal answer has no id, so the push stops after sending it.
    let _ = push(&ctx(&mac, &head, false));
    let sent = cmux_egress::capture::requests_to(host);
    assert!(sent.iter().any(|r| r.method == "POST" && r.target == "/v1/agent-home/proposals"));
    for marker in [
        "SEEDclaudeCredential",
        "SEEDclaudeSettings",
        "SEEDcodexAuth",
        "SEEDprojectEnv",
        "SEEDskillSecret",
    ] {
        let leaks = cmux_egress::capture::leaks(marker);
        assert!(leaks.is_empty(), "{marker} left: {leaks:?}");
    }
}
