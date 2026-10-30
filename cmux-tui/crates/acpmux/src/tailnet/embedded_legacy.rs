// Existing production controller, retained until the staged replacement is activated.
use super::*;

struct Inner {
    snapshot: Snapshot,
    node: Option<Arc<Node>>,
    starting: bool,
    generation: u64,
    /// Set by daemon shutdown and never cleared: no node starts after it.
    closed: bool,
}

/// Owns one embedded node per daemon install. The controller is cheap to
/// clone; all state and node handles remain shared and serialized.
pub struct Controller {
    state_dir: PathBuf,
    hostname: String,
    inner: Mutex<Inner>,
    changes: broadcast::Sender<Snapshot>,
    lifecycle: tokio::sync::Mutex<()>,
}

impl Controller {
    pub fn new(state_dir: impl Into<PathBuf>, hostname: impl Into<String>) -> Arc<Self> {
        let (changes, _) = broadcast::channel(32);
        Arc::new(Self {
            state_dir: state_dir.into(),
            hostname: hostname.into(),
            inner: Mutex::new(Inner {
                snapshot: Snapshot { state: "not_started", ..Snapshot::default() },
                node: None,
                starting: false,
                generation: 0,
                closed: false,
            }),
            changes,
            lifecycle: tokio::sync::Mutex::new(()),
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Snapshot> {
        self.changes.subscribe()
    }

    pub fn snapshot(&self) -> Snapshot {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner).snapshot.clone()
    }

    /// The live node for the ingress server. It remains valid through a
    /// restart; callers should subscribe and discard it when state stops.
    pub fn node(&self) -> Option<Arc<Node>> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner).node.clone()
    }

    /// Start the node without waiting for login. A saved login resumes; an
    /// unsigned node reports `needs_login` and its URL through `state`.
    pub async fn start(self: &Arc<Self>) -> Result<Snapshot, String> {
        let this = Arc::clone(self);
        detached(async move { this.start_detached().await }).await
    }

    /// Request an explicit browser sign-in URL for a running unsigned node.
    pub async fn login(self: &Arc<Self>) -> Result<Snapshot, String> {
        let this = Arc::clone(self);
        detached(async move { this.login_detached().await }).await
    }

    /// Sign out and close all ingress listeners that hold this node.
    pub async fn logout(self: &Arc<Self>) -> Result<Snapshot, String> {
        let this = Arc::clone(self);
        detached(async move { this.logout_detached().await }).await
    }

    /// Close without deleting the saved login, used by daemon shutdown.
    pub async fn shutdown(self: &Arc<Self>) -> Result<(), String> {
        let this = Arc::clone(self);
        detached(async move { this.shutdown_detached().await }).await
    }

    async fn start_detached(self: Arc<Self>) -> Result<Snapshot, String> {
        let _lifecycle = self.lifecycle.lock().await;
        let generation;
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            if inner.closed {
                return Err("the daemon is shutting down".to_owned());
            }
            if inner.node.is_some() || inner.starting {
                return Ok(inner.snapshot.clone());
            }
            inner.generation = inner.generation.wrapping_add(1);
            generation = inner.generation;
            inner.starting = true;
            inner.snapshot.state = "starting";
            inner.snapshot.error = None;
            self.publish_locked(&inner.snapshot);
        }
        let state_dir = self.state_dir.clone();
        let hostname = self.hostname.clone();
        let node = match tokio::task::spawn_blocking(move || {
            let config = NodeConfig::new(state_dir, hostname);
            let node = Node::new(&config).map_err(|error| error.0)?;
            node.start().map_err(|error| error.0)?;
            Ok::<_, String>(Arc::new(node))
        })
        .await
        .map_err(|error| error.to_string())
        .and_then(|started| started)
        {
            Ok(node) => node,
            Err(error) => {
                self.clear_node("error");
                self.update(|snapshot| snapshot.error = Some(error.clone()));
                return Err(error);
            }
        };
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.starting = false;
            inner.node = Some(node.clone());
        }
        let this = Arc::clone(&self);
        let watch_node = node.clone();
        if let Err(error) = std::thread::Builder::new()
            .name("acpmux-tailnet-watch".into())
            .spawn(move || this.watch(watch_node, generation))
        {
            release_node(node);
            self.clear_node("error");
            self.update(|snapshot| snapshot.error = Some(error.to_string()));
            return Err(error.to_string());
        }
        // A watch that already ended has cleared the node: this may be the last handle.
        release_node(node);
        Ok(self.snapshot())
    }

    async fn login_detached(self: Arc<Self>) -> Result<Snapshot, String> {
        let _lifecycle = self.lifecycle.lock().await;
        let node = self.node().ok_or_else(|| "tailnet is not started".to_owned())?;
        let result = tokio::task::spawn_blocking(move || node.login_interactive().map_err(|e| e.0))
            .await
            .map_err(|error| error.to_string())?;
        result?;
        Ok(self.snapshot())
    }

    async fn logout_detached(self: Arc<Self>) -> Result<Snapshot, String> {
        let _lifecycle = self.lifecycle.lock().await;
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.generation = inner.generation.wrapping_add(1);
        }
        let node = self.node();
        if let Some(node) = node {
            let result = tokio::task::spawn_blocking(move || {
                logout_and_close(
                    || node.logout().map_err(|e| e.0),
                    || node.close().map_err(|e| e.0),
                )
            })
            .await
            .map_err(|error| error.to_string())?;
            if let Err(error) = result {
                self.clear_node("error");
                self.update(|snapshot| snapshot.error = Some(error.clone()));
                return Err(error);
            }
        }
        self.clear_node("stopped");
        Ok(self.snapshot())
    }

    async fn shutdown_detached(self: Arc<Self>) -> Result<(), String> {
        {
            // Before waiting on the lifecycle lock: a start queued behind
            // this shutdown sees it and refuses.
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.closed = true;
        }
        let _lifecycle = self.lifecycle.lock().await;
        {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.generation = inner.generation.wrapping_add(1);
        }
        if let Some(node) = self.node() {
            let result = tokio::task::spawn_blocking(move || node.close().map_err(|e| e.0))
                .await
                .map_err(|error| error.to_string())?;
            if let Err(error) = result {
                self.clear_node("error");
                self.update(|snapshot| snapshot.error = Some(error.clone()));
                return Err(error);
            }
        }
        self.clear_node("stopped");
        Ok(())
    }

    fn watch(self: Arc<Self>, node: Arc<Node>, generation: u64) {
        let result = node.watch();
        match result {
            Ok(watch) => {
                for notify in watch {
                    let mut snapshot = self.snapshot();
                    snapshot.apply_notify(&notify, Some(&node));
                    self.publish_if_current(generation, snapshot);
                }
                self.clear_if_same(&node, generation, "stopped");
            }
            Err(error) => {
                self.update_if_current(generation, |snapshot| {
                    snapshot.state = "error";
                    snapshot.error = Some(error.0);
                });
                self.clear_if_same(&node, generation, "error");
            }
        }
    }

    fn clear_node(&self, state: &'static str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let node = inner.node.take();
        inner.starting = false;
        inner.snapshot.node_gone(state);
        self.publish_locked(&inner.snapshot);
        drop(inner);
        if let Some(node) = node {
            release_node(node);
        }
    }

    fn clear_if_same(&self, node: &Arc<Node>, generation: u64, state: &'static str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.generation == generation
            && inner.node.as_ref().is_some_and(|current| Arc::ptr_eq(current, node))
        {
            inner.node = None;
            inner.snapshot.node_gone(state);
            self.publish_locked(&inner.snapshot);
        }
    }

    fn update(&self, change: impl FnOnce(&mut Snapshot)) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        change(&mut inner.snapshot);
        self.publish_locked(&inner.snapshot);
    }

    fn update_if_current(&self, generation: u64, change: impl FnOnce(&mut Snapshot)) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.generation != generation {
            return;
        }
        change(&mut inner.snapshot);
        self.publish_locked(&inner.snapshot);
    }

    fn publish_if_current(&self, generation: u64, snapshot: Snapshot) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.generation != generation {
            return;
        }
        inner.snapshot = snapshot;
        self.publish_locked(&inner.snapshot);
    }

    fn publish_locked(&self, snapshot: &Snapshot) {
        let _ = self.changes.send(snapshot.clone());
    }
}
