//! The production adapters against real local sockets: no clone process
//! and no credentials are needed to exercise the git-seed/connector wire.

use super::*;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixListener;
use std::thread::JoinHandle;

struct Fixture {
    root: PathBuf,
    mux: Arc<Mux>,
    session: String,
}

impl Fixture {
    fn new() -> Self {
        let id = crate::workspace_registry::new_uuid_v4();
        let session = format!("repo-{id}");
        let root = std::env::temp_dir().join(format!("cmux-repo-{}", &id[..12]));
        std::fs::create_dir_all(&root).unwrap();
        let mux = Mux::new_for_test(&session, crate::SurfaceOptions::default());
        Self { root, mux, session }
    }

    fn runtime(&self) -> Runtime<'_> {
        Runtime {
            mux: &self.mux,
            home: self.root.join("home"),
            seed_socket: self.root.join("seed.sock"),
            agent_socket: self.root.join("agent.sock"),
        }
    }

    fn server(&self, name: &str, replies: Vec<Value>) -> JoinHandle<Vec<Value>> {
        let listener = UnixListener::bind(self.root.join(name)).unwrap();
        std::thread::spawn(move || {
            let mut requests = Vec::new();
            for reply in replies {
                // A faulty implementation that sends fewer calls fails the
                // test within five seconds rather than leaving accept hung.
                let mut ready =
                    libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
                // SAFETY: one live listener fd and one valid pollfd.
                assert_eq!(unsafe { libc::poll(&mut ready, 1, 5_000) }, 1);
                let (mut stream, _) = listener.accept().unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                stream.set_write_timeout(Some(Duration::from_secs(2))).unwrap();
                let mut line = String::new();
                BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
                requests.push(serde_json::from_str(&line).unwrap());
                writeln!(stream, "{reply}").unwrap();
            }
            requests
        })
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn seed_reply(value: Value) -> Value {
    json!({"id":"cloud-repo", "ok":true, "data":value})
}

fn done() -> Value {
    seed_reply(json!({"state":"done", "head":"0123456789abcdef", "head_ref":"main"}))
}

#[test]
fn cloud_repo_runtime_clones_through_seed_and_replays_the_record_without_a_second_clone() {
    let fixture = Fixture::new();
    let server = fixture.server("seed.sock", vec![seed_reply(json!({"job":"clone-1"})), done()]);
    let runtime = fixture.runtime();
    let args = json!({"session":fixture.session,"repo":"owner/tool","ref":"main"});
    let result = add(&runtime, &args).unwrap();
    assert_eq!(result["state"], "done");
    assert_eq!(
        result["folder"],
        json!(runtime.home.join("chats").join(&fixture.session).join("tool"))
    );
    assert_eq!(add(&runtime, &args).unwrap(), result);
    assert_eq!(runtime.attached(&fixture.session).unwrap(), vec![result]);
    assert_eq!(runtime.sources().unwrap()[0].full_name, "owner/tool");
    let requests = server.join().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0]["cmd"], "git.seed.start");
    assert_eq!(requests[0]["repo"], "owner/tool");
    assert_eq!(requests[0]["url"], "https://github.com/owner/tool.git");
    assert_eq!(requests[0]["ref"], "main");
    assert_eq!(
        requests[0]["folder"],
        json!(runtime.home.join("chats").join(&fixture.session).join("tool"))
    );
    assert_eq!(requests[1], json!({"id":"cloud-repo","cmd":"git.seed.status","job":"clone-1"}));
}

#[test]
fn cloud_repo_runtime_maps_every_seed_status_failure_and_clears_retryable_job() {
    for code in [
        "seed.needs_github",
        "seed.folder_not_empty",
        "seed.disk_full",
        "seed.clone_failed",
        "seed.bad_request",
    ] {
        let fixture = Fixture::new();
        let agent = (code == "seed.needs_github").then(|| fixture.server("agent.sock", vec![json!({
            "ok":true,"repos":[],"connect":{"install_url":"https://github.com/apps/cmux/installations/new"}
        })]));
        let server = fixture.server(
            "seed.sock",
            vec![
                seed_reply(json!({"job":"failed-job"})),
                seed_reply(json!({
                    "state":"failed", "error_code":code, "error":"raw internal detail",
                    "install_url":"https://github.com/apps/cmux/installations/new"
                })),
            ],
        );
        let runtime = fixture.runtime();
        let args = json!({"session":fixture.session,"repo":"owner/tool"});
        let failure = add(&runtime, &args).unwrap_err().0;
        assert_eq!(
            failure["code"],
            if code == "seed.needs_github" { "repo.needs_github" } else { code }
        );
        assert!(!failure["message"].as_str().unwrap().contains("raw internal detail"));
        assert!(!failure["message"].as_str().unwrap().is_empty());
        assert!(store::job(&fixture.mux, &fixture.session, "tool").unwrap().is_none());
        assert!(runtime.attached(&fixture.session).unwrap().is_empty());
        if code == "seed.needs_github" {
            assert_eq!(failure["install_url"], "https://github.com/apps/cmux/installations/new");
            assert_eq!(failure["retry"]["args"], args);
        }
        assert_eq!(server.join().unwrap().len(), 2);
        if let Some(agent) = agent {
            assert_eq!(agent.join().unwrap().len(), 1);
        }
    }
}

#[test]
fn cloud_repo_runtime_keeps_install_link_from_seed_start_refusal_details() {
    let fixture = Fixture::new();
    let agent = fixture.server("agent.sock", vec![json!({
        "ok":true,"repos":[],"connect":{"install_url":"https://github.com/apps/cmux/installations/new"}
    })]);
    let server = fixture.server(
        "seed.sock",
        vec![json!({
            "ok":false, "error_code":"seed.needs_github", "error":"connect first",
            "error_details":{"install_url":"https://github.com/apps/cmux/installations/new"}
        })],
    );
    let failure = add(&fixture.runtime(), &json!({"session":fixture.session,"repo":"owner/tool"}))
        .unwrap_err()
        .0;
    assert_eq!(failure["code"], "repo.needs_github");
    assert_eq!(failure["install_url"], "https://github.com/apps/cmux/installations/new");
    assert_eq!(server.join().unwrap()[0]["cmd"], "git.seed.start");
    assert_eq!(agent.join().unwrap().len(), 1);
}

#[test]
fn cloud_repo_runtime_seed_start_auth_refusal_uses_synced_link() {
    let fixture = Fixture::new();
    let install_url = "https://github.com/apps/cmux/installations/new";
    store::sync(&fixture.mux, &json!({"repos":[],"install_url":install_url})).unwrap();
    let agent = fixture.server("agent.sock", vec![json!({"ok":true,"repos":[],"connect":{}})]);
    let seed =
        fixture.server("seed.sock", vec![json!({"ok":false,"error_code":"seed.needs_github"})]);
    let failure = add(&fixture.runtime(), &json!({"session":fixture.session,"repo":"owner/tool"}))
        .unwrap_err()
        .0;
    assert_eq!(failure["code"], "repo.needs_github");
    assert_eq!(failure["install_url"], install_url);
    assert_eq!(seed.join().unwrap().len(), 1);
    assert_eq!(agent.join().unwrap()[0], json!({"github_repos":{"query":"owner/tool"}}));
}

#[test]
fn cloud_repo_runtime_connected_installation_missing_repository_requests_org_access() {
    let fixture = Fixture::new();
    let install_url = "https://github.com/apps/cmux/installations/new";
    store::sync(&fixture.mux, &json!({"repos":[],"install_url":install_url})).unwrap();
    let agent = fixture.server("agent.sock", vec![json!({"ok":true,"repos":[]})]);
    let seed =
        fixture.server("seed.sock", vec![json!({"ok":false,"error_code":"seed.needs_github"})]);
    let failure =
        add(&fixture.runtime(), &json!({"session":fixture.session,"repo":"organization/tool"}))
            .unwrap_err()
            .0;
    assert_eq!(failure["code"], "repo.no_access");
    assert_eq!(failure["install_url"], install_url);
    assert_eq!(failure["org"], "organization");
    assert!(failure.get("retry").is_none());
    assert_eq!(seed.join().unwrap().len(), 1);
    assert_eq!(agent.join().unwrap().len(), 1);
}

#[test]
fn cloud_repo_runtime_unknown_saved_job_is_restarted_on_retry() {
    for code in ["seed.bad_request", "seed.unknown_job"] {
        unknown_saved_job_is_restarted(code);
    }
}

/// git-seed-v1 answers `seed.unknown_job` for a job its daemon no longer
/// has; older answers said `seed.bad_request`.
fn unknown_saved_job_is_restarted(code: &str) {
    let fixture = Fixture::new();
    store::set_job(
        &fixture.mux,
        &fixture.session,
        "tool",
        Some(&json!({
            "job":"expired", "repo":"owner/tool", "ref":null
        })),
    )
    .unwrap();
    let seed = fixture.server(
        "seed.sock",
        vec![
            json!({"ok":false,"error_code":code,"error":"unknown job"}),
            seed_reply(json!({"job":"fresh"})),
            done(),
        ],
    );
    let runtime = fixture.runtime();
    let args = json!({"session":fixture.session,"repo":"owner/tool"});
    assert_eq!(add(&runtime, &args).unwrap_err().0["code"], code);
    assert!(store::job(&fixture.mux, &fixture.session, "tool").unwrap().is_none());
    assert_eq!(add(&runtime, &args).unwrap()["state"], "done");
    let calls = seed.join().unwrap();
    assert_eq!(calls[0]["cmd"], "git.seed.status");
    assert_eq!(calls[1]["cmd"], "git.seed.start");
    assert_eq!(calls[2]["job"], "fresh");
}

#[test]
fn cloud_repo_runtime_transport_failure_keeps_saved_job_for_resume() {
    let fixture = Fixture::new();
    store::set_job(
        &fixture.mux,
        &fixture.session,
        "tool",
        Some(&json!({
            "job":"in-flight", "repo":"owner/tool", "ref":null
        })),
    )
    .unwrap();
    let failure = add(&fixture.runtime(), &json!({"session":fixture.session,"repo":"owner/tool"}))
        .unwrap_err()
        .0;
    assert_eq!(failure["code"], "seed.clone_failed");
    assert_eq!(
        store::job(&fixture.mux, &fixture.session, "tool").unwrap().unwrap()["job"],
        "in-flight"
    );
}

#[test]
fn cloud_repo_runtime_uses_actual_bound_custom_daemon_socket() {
    let fixture = Fixture::new();
    let path = fixture.root.join("custom-daemon.sock");
    let pending = crate::server::bind_session_socket(&fixture.session, Some(path.clone()))
        .unwrap()
        .serve_restoring()
        .unwrap()
        .attach(fixture.mux.clone());
    let runtime = Runtime::new(&fixture.mux, fixture.root.join("home"));
    assert_eq!(runtime.seed_socket, path);
    drop(pending);
}

#[test]
fn cloud_repo_runtime_resumes_saved_seed_job_without_starting_a_duplicate() {
    let fixture = Fixture::new();
    store::set_job(
        &fixture.mux,
        &fixture.session,
        "tool",
        Some(&json!({
            "job":"saved-job", "repo":"owner/tool", "ref":null
        })),
    )
    .unwrap();
    let server = fixture.server("seed.sock", vec![done()]);
    assert_eq!(
        add(&fixture.runtime(), &json!({"session":fixture.session,"repo":"owner/tool"})).unwrap()["state"],
        "done"
    );
    assert_eq!(
        server.join().unwrap(),
        vec![json!({"id":"cloud-repo","cmd":"git.seed.status","job":"saved-job"})]
    );
}

#[test]
fn cloud_repo_runtime_missing_github_recovers_and_retries_identical_add() {
    let fixture = Fixture::new();
    let install_url = "https://github.com/apps/cmux/installations/new";
    store::sync(&fixture.mux, &json!({"repos":[], "complete":true, "install_url":install_url}))
        .unwrap();
    let connected = json!({"ok":true,"repos":[{"fullName":"owner/tool","private":true}]});
    let agent = fixture.server(
        "agent.sock",
        vec![
            json!({"ok":true,"repos":[],"connect":{}}),
            json!({"ok":true,"repos":[],"connect":{}}),
            connected.clone(),
            connected,
        ],
    );
    let seed = fixture.server("seed.sock", vec![seed_reply(json!({"job":"recovered"})), done()]);
    let runtime = fixture.runtime();
    let args = json!({"session":fixture.session,"repo":"tool"});
    let failure = add(&runtime, &args).unwrap_err().0;
    assert_eq!(failure["code"], "repo.needs_github");
    assert_eq!(failure["install_url"], install_url);
    assert_eq!(failure["retry"]["args"], args);
    assert_eq!(runtime.wait_github(0).unwrap(), json!({"connected":false}));
    assert_eq!(runtime.wait_github(0).unwrap(), json!({"connected":true}));
    let attached = add(&runtime, &args).unwrap();
    assert_eq!(attached["repo"], "owner/tool");
    assert_eq!(runtime.attached(&fixture.session).unwrap(), vec![attached]);
    let asks = agent.join().unwrap();
    assert_eq!(asks[0], json!({"github_repos":{"query":"tool"}}));
    assert_eq!(asks[1], json!({"github_repos":{}}));
    assert_eq!(asks[2], json!({"github_repos":{}}));
    assert_eq!(asks[3], asks[0]);
    assert_eq!(seed.join().unwrap().len(), 2);
}

#[test]
fn cloud_repo_runtime_connector_pages_and_rejects_repeated_cursor() {
    let fixture = Fixture::new();
    let agent = fixture.server("agent.sock", vec![
        json!({"ok":true,"repos":[{"fullName":"a/tool","private":false}],"next_cursor":"page-2"}),
        json!({"ok":true,"repos":[{"fullName":"b/tool","private":true}]}),
        json!({"ok":true,"repos":[],"next_cursor":"again"}),
        json!({"ok":true,"repos":[],"next_cursor":"again"}),
    ]);
    let runtime = fixture.runtime();
    let catalog = runtime.connector(Some("tool")).unwrap();
    assert_eq!(catalog.repos.len(), 2);
    assert_eq!(catalog.repos[0].source, "installation");
    assert!(!catalog.repos[0].private);
    assert!(runtime.connector(None).is_err());
    let asks = agent.join().unwrap();
    assert_eq!(asks[1], json!({"github_repos":{"query":"tool","cursor":"page-2"}}));
    assert_eq!(asks[3], json!({"github_repos":{"cursor":"again"}}));
}
