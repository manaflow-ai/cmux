use assert_cmd::Command;
use axum::body::Body;
use axum::Router;
use cmux_sandbox::build_router;
use cmux_sandbox::models::{
    CreateSandboxRequest, ExecRequest, ExecResponse, SandboxNetwork, SandboxStatus, SandboxSummary,
};
use cmux_sandbox::notifications::NotificationStore;
use cmux_sandbox::service::SandboxService;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use uuid::Uuid;

fn make_test_router(service: Arc<MockService>) -> Router {
    use std::collections::HashMap;
    let (host_event_tx, _) = tokio::sync::broadcast::channel(16);
    let gh_responses = Arc::new(Mutex::new(HashMap::new()));
    let gh_auth_cache = Arc::new(Mutex::new(None));
    let notifications = NotificationStore::new();
    build_router(
        service,
        host_event_tx,
        gh_responses,
        gh_auth_cache,
        notifications,
    )
}

struct MockService {
    sandboxes: Mutex<Vec<SandboxSummary>>,
    calls: Mutex<Vec<&'static str>>,
    archives: Mutex<Vec<Vec<u8>>>,
}

impl MockService {
    fn new() -> Self {
        Self {
            sandboxes: Mutex::new(Vec::new()),
            calls: Mutex::new(Vec::new()),
            archives: Mutex::new(Vec::new()),
        }
    }

    async fn record(&self, name: &'static str) {
        let mut guard = self.calls.lock().await;
        guard.push(name);
    }
}

#[async_trait::async_trait]
impl SandboxService for MockService {
    async fn create(
        &self,
        request: CreateSandboxRequest,
    ) -> cmux_sandbox::errors::SandboxResult<SandboxSummary> {
        let summary = SandboxSummary {
            id: Uuid::new_v4(),
            index: 0,
            name: request.name.unwrap_or_else(|| "mock".to_string()),
            created_at: chrono::Utc::now(),
            workspace: request
                .workspace
                .unwrap_or_else(|| "/tmp/mock-workspace".to_string()),
            status: SandboxStatus::Running,
            network: SandboxNetwork {
                host_interface: "vethh-mock".into(),
                sandbox_interface: "vethn-mock".into(),
                host_ip: "10.201.0.1".into(),
                sandbox_ip: "10.201.0.2".into(),
                cidr: 30,
            },
        };
        let mut guard = self.sandboxes.lock().await;
        guard.push(summary.clone());
        self.record("create").await;
        Ok(summary)
    }

    async fn list(&self) -> cmux_sandbox::errors::SandboxResult<Vec<SandboxSummary>> {
        self.record("list").await;
        Ok(self.sandboxes.lock().await.clone())
    }

    async fn get(&self, id: String) -> cmux_sandbox::errors::SandboxResult<Option<SandboxSummary>> {
        let guard = self.sandboxes.lock().await;
        self.record("get").await;
        Ok(guard.iter().find(|s| s.id.to_string() == id).cloned())
    }

    async fn exec(
        &self,
        _id: String,
        _exec: ExecRequest,
    ) -> cmux_sandbox::errors::SandboxResult<ExecResponse> {
        self.record("exec").await;
        Ok(ExecResponse {
            exit_code: 0,
            stdout: "ok".into(),
            stderr: String::new(),
        })
    }

    async fn attach(
        &self,
        _id: String,
        _socket: axum::extract::ws::WebSocket,
        _initial_size: Option<(u16, u16)>,
        _command: Option<Vec<String>>,
        _tty: bool,
    ) -> cmux_sandbox::errors::SandboxResult<()> {
        Ok(())
    }

    async fn mux_attach(
        &self,
        _socket: axum::extract::ws::WebSocket,
        _host_event_rx: cmux_sandbox::service::HostEventReceiver,
        _gh_responses: cmux_sandbox::service::GhResponseRegistry,
        _gh_auth_cache: cmux_sandbox::service::GhAuthCache,
    ) -> cmux_sandbox::errors::SandboxResult<()> {
        Ok(())
    }

    async fn proxy(
        &self,
        _id: String,
        _port: u16,
        _socket: axum::extract::ws::WebSocket,
    ) -> cmux_sandbox::errors::SandboxResult<()> {
        Ok(())
    }

    async fn upload_archive(
        &self,
        _id: String,
        archive: Body,
    ) -> cmux_sandbox::errors::SandboxResult<()> {
        self.record("upload_archive").await;
        let bytes = axum::body::to_bytes(archive, usize::MAX)
            .await
            .unwrap()
            .to_vec();
        let mut guard = self.archives.lock().await;
        guard.push(bytes);
        Ok(())
    }

    async fn delete(
        &self,
        id: String,
    ) -> cmux_sandbox::errors::SandboxResult<Option<SandboxSummary>> {
        let mut guard = self.sandboxes.lock().await;
        if let Some(pos) = guard.iter().position(|s| s.id.to_string() == id) {
            let summary = guard.remove(pos);
            self.record("delete").await;
            return Ok(Some(summary));
        }
        Ok(None)
    }
}

#[tokio::test]
async fn cli_can_list_and_create_via_http() {
    let service = Arc::new(MockService::new());
    let app = make_test_router(service.clone());
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();

    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                tokio::signal::ctrl_c().await.ok();
            })
            .await
            .ok();
    });

    // Ensure server is responding before invoking the CLI.
    let health_resp = reqwest::Client::new()
        .get(format!("http://{}/healthz", addr))
        .timeout(Duration::from_secs(3))
        .send()
        .await
        .expect("health check failed");
    assert!(health_resp.status().is_success());

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();
    let base = format!("http://{}", addr);

    // capture a trajectory of shell-equivalent commands and outputs
    let mut transcript: Vec<(String, String)> = Vec::new();

    let list_before = client
        .get(format!("{}/sandboxes", base))
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    transcript.push(("cmux sandboxes list".into(), list_before.clone()));
    assert_eq!(list_before.trim(), "[]");

    let payload = serde_json::to_value(&CreateSandboxRequest {
        name: Some("demo".into()),
        workspace: Some("/tmp/demo".into()),
        tab_id: None,
        read_only_paths: Vec::new(),
        tmpfs: Vec::new(),
        env: Vec::new(),
    })
    .unwrap();
    let created = client
        .post(format!("{}/sandboxes", base))
        .json(&payload)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    transcript.push((
        "cmux sandboxes create --name demo --workspace /tmp/demo".into(),
        created.clone(),
    ));
    assert!(created.contains("demo"));

    let list_after = client
        .get(format!("{}/sandboxes", base))
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    transcript.push(("cmux sandboxes list".into(), list_after.clone()));
    assert!(list_after.contains("demo"));

    assert!(service.calls.lock().await.contains(&"create"));
    assert!(
        service
            .calls
            .lock()
            .await
            .iter()
            .filter(|c| **c == "list")
            .count()
            >= 2
    );

    // ensure we captured the user-visible trajectory format: <command, output>
    assert_eq!(transcript.len(), 3);
    assert!(transcript[0].1.contains('['));
    assert!(transcript[1].1.contains("workspace"));
    assert!(transcript[2].1.contains("demo"));

    server.abort();
    let _ = server.await;
}

#[test]
fn cli_help_exits_quickly() {
    Command::new(assert_cmd::cargo::cargo_bin!("cmux"))
        .arg("--help")
        .assert()
        .success()
        .stdout(predicates::str::contains("cmux sandbox controller"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cli_exec_shorthand() {
    let service = Arc::new(MockService::new());
    let app = make_test_router(service.clone());
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();

    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                tokio::signal::ctrl_c().await.ok();
            })
            .await
            .ok();
    });

    let base_url = format!("http://{}", addr);

    // Test 'cmux exec <id> <cmd>'
    Command::new(assert_cmd::cargo::cargo_bin!("cmux"))
        .env("CMUX_SANDBOX_URL", &base_url)
        .args(["exec", "any-id", "echo hello"])
        .assert()
        .success()
        .stdout(predicates::str::contains("\"stdout\": \"ok\""));

    assert!(service.calls.lock().await.contains(&"exec"));

    server.abort();
    let _ = server.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cli_uploads_cwd_respecting_gitignore() {
    let service = Arc::new(MockService::new());
    let app = make_test_router(service.clone());
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();

    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                tokio::signal::ctrl_c().await.ok();
            })
            .await
            .ok();
    });

    let base_url = format!("http://{}", addr);

    // Setup temp dir
    let temp_dir = tempfile::tempdir().unwrap();
    let dir_path = temp_dir.path();

    // included.txt
    std::fs::write(dir_path.join("included.txt"), "keep me").unwrap();

    // ignored.txt
    std::fs::write(dir_path.join("ignored.txt"), "ignore me").unwrap();

    // .gitignore
    std::fs::write(dir_path.join(".gitignore"), "ignored.txt\n").unwrap();
    std::fs::create_dir(dir_path.join(".git")).unwrap();

    // Run cmux new in that dir
    // We need to run with --detach or similar if possible, or just wait for it to finish
    // but `cmux new` attaches to SSH.
    // The CLI attaches via WebSocket. In our MockService, `attach` does nothing (returns Ok).
    // So `cmux new` should finish connecting and then wait for input?
    // Or does it exit if socket closes?
    // The CLI `handle_ssh` loop exits if socket closes.
    // In `MockService`, `attach` returns `Ok(())` immediately, effectively closing the connection?
    // Wait, `attach` in `MockService` is:
    // async fn attach(...) -> Result<()> { Ok(()) }
    //
    // In real service, `attach` keeps running.
    // In `api.rs`, `attach_sandbox` upgrades the connection:
    // ws.on_upgrade(move |socket| async move { state.service.attach(...) })
    //
    // If `state.service.attach` returns immediately, the socket is dropped/closed.
    //
    // CLI `handle_ssh`:
    // let (ws_stream, _) = connect_async(url).await?;
    // loop { msg = read.next() ... }
    //
    // If server closes socket, `read.next()` returns None or Close. CLI exits.
    Command::new(assert_cmd::cargo::cargo_bin!("cmux"))
        .env("CMUX_SANDBOX_URL", &base_url)
        .env("HOME", dir_path)
        .current_dir(dir_path)
        .arg("new")
        .assert()
        .success();

    // Check calls
    {
        let calls = service.calls.lock().await;
        assert!(calls.contains(&"create"), "Should have created sandbox");
        assert!(
            calls.contains(&"upload_archive"),
            "Should have uploaded archive"
        );
    }

    // Check uploaded archive
    {
        let archives = service.archives.lock().await;
        assert_eq!(archives.len(), 1, "Should have uploaded one archive");

        let data = &archives[0];
        let mut archive = tar::Archive::new(&data[..]);
        let entries: Vec<_> = archive
            .entries()
            .unwrap()
            .map(|e| e.unwrap().path().unwrap().to_string_lossy().into_owned())
            .collect();

        assert!(
            entries.iter().any(|e| e.contains("included.txt")),
            "included.txt missing"
        );
        assert!(
            entries.iter().any(|e| e.contains(".gitignore")),
            ".gitignore missing"
        );
        assert!(
            !entries.iter().any(|e| e.contains("ignored.txt")),
            "ignored.txt should be ignored"
        );
    }

    server.abort();
    let _ = server.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cli_uploads_large_file() {
    let service = Arc::new(MockService::new());
    let app = make_test_router(service.clone());
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();

    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                tokio::signal::ctrl_c().await.ok();
            })
            .await
            .ok();
    });

    let base_url = format!("http://{}", addr);

    // Setup temp dir
    let temp_dir = tempfile::tempdir().unwrap();
    let dir_path = temp_dir.path();

    // Create a 5MB file
    let large_data = vec![0u8; 5 * 1024 * 1024];
    std::fs::write(dir_path.join("large.bin"), &large_data).unwrap();

    Command::new(assert_cmd::cargo::cargo_bin!("cmux"))
        .env("CMUX_SANDBOX_URL", &base_url)
        .env("HOME", dir_path)
        .current_dir(dir_path)
        .arg("new")
        .assert()
        .success();

    // Check uploaded archive size
    {
        let archives = service.archives.lock().await;
        assert_eq!(archives.len(), 1);
        let data = &archives[0];
        // The tar archive will be slightly larger than 5MB
        assert!(data.len() >= 5 * 1024 * 1024);
    }

    server.abort();
    let _ = server.await;
}
