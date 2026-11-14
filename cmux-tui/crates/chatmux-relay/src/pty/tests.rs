use super::*;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::Ordering as AtomicOrdering;

static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(0);

/// A unique, real directory for tests that exercise cwd canonicalization.
/// Do not reuse a process-id-only path: tests run in parallel and a stale
/// path from an interrupted run must never be removed or reused.
struct TestDirectory {
    path: PathBuf,
}

impl TestDirectory {
    fn new(label: &str) -> TestDirectory {
        loop {
            let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, AtomicOrdering::Relaxed);
            let process_id = std::process::id();
            let path =
                std::env::temp_dir().join(format!("chatmux-pty-{label}-{process_id}-{sequence}"));
            match std::fs::create_dir(&path) {
                Ok(()) => return TestDirectory { path },
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create PTY test directory failed: {error}"),
            }
        }
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// A fake PTY: emit() calls the subscribed sink synchronously, like the
/// JS fakePty. Records writes/resizes/pause/kill for assertions.
#[derive(Default)]
struct FakeState {
    on_data: Option<DataSink>,
    on_exit: Option<ExitSink>,
    written: Vec<Vec<u8>>,
    resized: Vec<(u16, u16)>,
    paused: bool,
    killed: bool,
}

#[derive(Clone)]
struct FakePty {
    state: Arc<StdMutex<FakeState>>,
}

impl PtyControl for FakePty {
    fn write(&self, data: &[u8]) {
        self.state.lock().unwrap().written.push(data.to_vec());
    }
    fn resize(&self, cols: u16, rows: u16) {
        self.state.lock().unwrap().resized.push((cols, rows));
    }
    fn pause(&self) {
        self.state.lock().unwrap().paused = true;
    }
    fn resume(&self) {
        self.state.lock().unwrap().paused = false;
    }
    fn kill(&self) {
        self.state.lock().unwrap().killed = true;
    }
}

impl PtyOutput for FakePty {
    fn subscribe(&self, on_data: DataSink, on_exit: ExitSink) {
        let mut state = self.state.lock().unwrap();
        state.on_data = Some(on_data);
        state.on_exit = Some(on_exit);
    }
}

#[derive(Default)]
struct Recorded {
    spawned: Vec<FakePty>,
    daemons: Vec<(String, PathBuf)>,
    connected: Vec<PathBuf>,
}

struct FakeDeps {
    env: HashMap<String, String>,
    recorded: Arc<StdMutex<Recorded>>,
    resolve: Option<CmuxTui>,
    socket_dir: PathBuf,
    read_dir: Option<Vec<String>>,
    ensure_socket_path: Option<PathBuf>,
    control: Option<Arc<dyn ControlHandle>>,
}

#[async_trait]
impl PtyDeps for FakeDeps {
    async fn spawn_pty(&self, _spec: SpawnSpec) -> PtyHandle {
        let pty = FakePty { state: Arc::new(StdMutex::new(FakeState::default())) };
        self.recorded.lock().unwrap().spawned.push(pty.clone());
        let control: Arc<dyn PtyControl> = Arc::new(pty.clone());
        let output: Arc<dyn PtyOutput> = Arc::new(pty);
        PtyHandle { control, output, banner: None }
    }
    async fn resolve_cmux_tui(&self) -> Option<CmuxTui> {
        self.resolve.clone()
    }
    async fn ensure_daemon(
        &self,
        _cmux_tui: &CmuxTui,
        session: &str,
        socket_dir: &Path,
        _cwd: &ResolvedCwd,
        _env: &HashMap<String, String>,
    ) -> Result<EnsureDaemon, String> {
        self.recorded.lock().unwrap().daemons.push((session.to_owned(), socket_dir.to_path_buf()));
        let socket_path = self
            .ensure_socket_path
            .clone()
            .unwrap_or_else(|| socket_dir.join(format!("{session}.sock")));
        Ok(EnsureDaemon { created: true, socket_path })
    }
    async fn connect_control(&self, socket_path: &Path) -> Result<Arc<dyn ControlHandle>, String> {
        self.recorded.lock().unwrap().connected.push(socket_path.to_path_buf());
        match &self.control {
            Some(control) => Ok(Arc::clone(control)),
            None => Err("no control socket in tests unless injected".to_owned()),
        }
    }
    async fn read_dir(&self, _path: &Path) -> Result<Vec<String>, ()> {
        self.read_dir.clone().ok_or(())
    }
    fn socket_dir(&self) -> PathBuf {
        self.socket_dir.clone()
    }
    fn shell(&self) -> String {
        self.env.get("SHELL").cloned().unwrap_or_else(|| "/bin/sh".to_owned())
    }
}

struct Harness {
    manager: PtyManager,
    sent: Arc<StdMutex<Vec<Value>>>,
    buffered: Arc<AtomicU64>,
    owner: Option<String>,
    _home: TestDirectory,
}

fn env_map(home: &Path) -> HashMap<String, String> {
    HashMap::from([
        ("SHELL".to_owned(), "/bin/fakesh".to_owned()),
        ("PATH".to_owned(), "/usr/bin".to_owned()),
        ("HOME".to_owned(), home.to_string_lossy().into_owned()),
    ])
}

fn harness(resolve: Option<CmuxTui>, read_dir: Option<Vec<String>>) -> Harness {
    harness_with_socket_path(resolve, read_dir, None)
}

fn harness_with_socket_path(
    resolve: Option<CmuxTui>,
    read_dir: Option<Vec<String>>,
    ensure_socket_path: Option<PathBuf>,
) -> Harness {
    harness_with_control(resolve, read_dir, ensure_socket_path, None)
}

fn harness_with_control(
    resolve: Option<CmuxTui>,
    read_dir: Option<Vec<String>>,
    ensure_socket_path: Option<PathBuf>,
    control: Option<Arc<dyn ControlHandle>>,
) -> Harness {
    let home = TestDirectory::new("harness");
    let home_path = home.path.clone();
    let env = env_map(&home_path);
    let recorded = Arc::new(StdMutex::new(Recorded::default()));
    let socket_dir = PathBuf::from("/run/cmux-tui-501");
    let deps = Arc::new(FakeDeps {
        env: env.clone(),
        recorded: Arc::clone(&recorded),
        resolve,
        socket_dir,
        read_dir,
        ensure_socket_path,
        control,
    });
    let manager = PtyManager::with_limits(
        deps,
        home_path,
        env,
        MAX_PTYS,
        SCROLLBACK_LIMIT,
        OUTPUT_BUFFER_CAP,
    );
    Harness {
        manager,
        sent: Arc::new(StdMutex::new(Vec::new())),
        buffered: Arc::new(AtomicU64::new(0)),
        owner: Some("user_owner".to_owned()),
        _home: home,
    }
}

impl Harness {
    fn context(&self, trust: &str, owner: Option<String>) -> FrameContext {
        let sent = Arc::clone(&self.sent);
        let buffered = Arc::clone(&self.buffered);
        FrameContext {
            send: Arc::new(move |frame| sent.lock().unwrap().push(frame)),
            buffered_amount: Arc::new(move || buffered.load(Ordering::SeqCst)),
            trust: trust.to_owned(),
            local_roots: None,
            owner_user_id: owner,
            transport_id: None,
            cancellation: CancellationToken::new(),
        }
    }

    async fn open(
        &self,
        pty_id: &str,
        session: &str,
        extra: Value,
        trust: &str,
        owner: Option<String>,
    ) {
        let mut frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": pty_id,
            "session": session,
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
            "trust": "supervised",
            "allowedRoots": Value::Null,
        });
        if let Value::Object(extra) = extra {
            for (k, v) in extra {
                frame[k] = v;
            }
        }
        self.manager.handle_frame(&frame, &self.context(trust, owner)).await;
    }

    fn sent(&self) -> Vec<Value> {
        self.sent.lock().unwrap().clone()
    }
}

fn ty(frame: &Value) -> &str {
    frame.get("type").and_then(Value::as_str).unwrap_or_default()
}

#[tokio::test]
async fn observe_trust_refuses_non_owner_but_admits_owner() {
    let h = harness(None, None);
    h.open(
        "p1",
        "main",
        serde_json::json!({ "actorId": "user_other" }),
        "observe",
        h.owner.clone(),
    )
    .await;
    assert_eq!(h.sent()[0]["code"], "trust_refused");
    h.open("p2", "main", Value::Null, "observe", h.owner.clone()).await;
    assert_eq!(ty(&h.sent()[1]), "pty_opened");
}

#[tokio::test]
async fn observe_trust_with_unknown_owner_refuses() {
    let h = harness(None, None);
    h.open("p1", "main", Value::Null, "observe", None).await;
    assert_eq!(h.sent()[0]["code"], "trust_refused");
}
