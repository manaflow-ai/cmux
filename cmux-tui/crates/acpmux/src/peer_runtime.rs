//! Core peer lifecycle and request handling.
//!
//! Kept separate from the type declarations so the parent module stays below the
//! NEXT god-file size budget.

use super::*;

impl Peer {
    pub(crate) fn cache_is_dirty(&self) -> bool {
        self.cache_dirty_seq.load(Ordering::Acquire)
            != self.cache_flushed_seq.load(Ordering::Acquire)
    }

    pub fn new(
        name: &str,
        url: &str,
        token: Option<String>,
        peer_token: Option<String>,
        notices: mpsc::Sender<(String, u64, PeerNotice)>,
    ) -> Arc<Self> {
        let (out, out_rx) = mpsc::channel(1024);
        Arc::new(Self {
            scope: cmux_scope::Scope::new("acpmux peer"),
            name: name.to_owned(),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::SeqCst),
            url: url.to_owned(),
            token,
            peer_token,
            tunnel: Mutex::new(None),
            wireguard: std::sync::OnceLock::new(),
            #[cfg(feature = "hub-carrier")]
            hub_carrier: std::sync::OnceLock::new(),
            link_host: std::sync::OnceLock::new(),
            explicit_route: AtomicBool::new(false),
            link_socket: std::sync::OnceLock::new(),
            paths: StdMutex::new(None),
            serving: StdMutex::new(None),
            switch_wanted: AtomicBool::new(false),
            probing: AtomicBool::new(false),
            answering: carriers::Answering::default(),
            last_good: std::sync::OnceLock::new(),
            shadow: StdMutex::new(None),
            dual_sessions: StdMutex::new(HashSet::new()),
            dual_merge: Mutex::new(dual::Merger::default()),
            token_paths: StdMutex::new(HashMap::new()),
            replaying: StdMutex::new(HashMap::new()),
            carried: Default::default(),
            switched: AtomicBool::new(false),
            dual_nonce: uuid::Uuid::now_v7().simple().to_string(),
            dual_frames: AtomicU64::new(0),
            dual_stats: dual::DualStats::default(),
            out,
            out_rx: Mutex::new(Some(out_rx)),
            next_id: AtomicI64::new(1),
            pending: Arc::new(Mutex::new(HashMap::new())),
            on_wire: Default::default(),
            cancelled: Default::default(),
            prompts: Default::default(),
            connected: AtomicBool::new(false),
            rows_ready: AtomicBool::new(false),
            rows_link: AtomicU64::new(0),
            listed_links: StdMutex::new(std::collections::VecDeque::new()),
            open: AtomicBool::new(false),
            last_error: StdMutex::new(None),
            facts: StdMutex::new(carrier::LinkFacts::default()),
            remote_version: StdMutex::new(None),
            row_pages_for: StdMutex::new(None),
            served_as: StdMutex::new(None),
            person_instance: StdMutex::new(None),
            trust_gate: AtomicBool::new(false),
            vm_boundary: AtomicBool::new(false),
            github_broker: AtomicBool::new(false),
            github_slots: crate::github_broker::owner_slots(name),
            github_link: AtomicU64::new(0),
            github_revoked: tokio::sync::Notify::new(),
            github_app: std::sync::OnceLock::new(),
            file_put: AtomicBool::new(false),
            file_put_chunks: AtomicBool::new(false),
            media_read: AtomicBool::new(false),
            link_epoch: Arc::new(AtomicU64::new(0)),
            subagent_transcript: AtomicBool::new(false),
            native_history: AtomicBool::new(false),
            session_auth: AtomicBool::new(false),
            features: StdMutex::new(Vec::new()),
            session_resume_link: AtomicU64::new(0),
            session_messages: AtomicBool::new(false),
            person_stop: AtomicBool::new(false),
            withheld: AtomicBool::new(false),
            presented: StdMutex::new(None),
            read_tokens: tokens::TokenCache::default(),
            linked_once: AtomicBool::new(false),
            slow_banner: AtomicBool::new(false),
            admitting: AtomicBool::new(false),
            attached: StdMutex::new(HashMap::new()),
            marks: AtomicU64::new(0),
            cursors: StdMutex::new(HashMap::new()),
            baselined: StdMutex::new(HashSet::new()),
            attach_retries: StdMutex::new(HashSet::new()),
            replay_highwater: StdMutex::new(HashMap::new()),
            replay_tail: StdMutex::new(HashMap::new()),
            notices,
            stop: AtomicBool::new(false),
            retry_immediately: AtomicBool::new(false),
            stop_signal: Notify::new(),
            stop_changed: tokio::sync::watch::channel(false).0,
            wanted: Default::default(),
            settled: tokio::sync::watch::channel(0).0,
            link: StdMutex::new(Link::default()),
            states: StdMutex::new(None),
            timings: LinkTimings::from_env(),
            silence: StdMutex::new(None),
            cache_saved_at: AtomicU64::new(0),
            cache_saved_outage: AtomicBool::new(false),
            cache_write_pending: AtomicBool::new(false),
            cache_dirty_seq: AtomicU64::new(0),
            cache_flushed_seq: AtomicU64::new(0),
            remote_rows_epoch: AtomicU64::new(0),
            remote_purge_fences: StdMutex::new(HashSet::new()),
            outage_ended: AtomicBool::new(false),
            purge_tombstones: Default::default(),
            health: StdMutex::new(None),
            health_asking: AtomicBool::new(false),
            watch_key: StdMutex::new(None),
            pipelined_key: StdMutex::new(None),
            pipelines: AtomicBool::new(false),
            list_follow: AtomicBool::new(false),
            list_cursor: StdMutex::new(None),
            cursor_tools: AtomicBool::new(false),
            received: ReceivedBytes::default(),
        })
    }

    pub(crate) fn set_wireguard(
        &self,
        transport: Arc<crate::wireguard::Transport>,
        address: std::net::SocketAddr,
    ) {
        let _ = self.wireguard.set((transport, address));
    }

    /// What the current (or last) link received (`ReceivedBytes`).
    pub fn received(&self) -> &ReceivedBytes {
        &self.received
    }

    pub fn link(&self) -> Link {
        self.link.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn with_silence<T>(&self, f: impl FnOnce(&mut SilenceBudget) -> T) -> T {
        let mut budget = self.silence.lock().unwrap_or_else(|e| e.into_inner());
        f(budget.get_or_insert_with(|| SilenceBudget::new(&self.timings)))
    }

    /// Every change of the link's state goes through here, so each one sends its note
    /// (`report_states`) from the code that made it: no timer, no polling, no repeats.
    fn with_link<T>(&self, f: impl FnOnce(&mut Link) -> T) -> T {
        let mut link = self.link.lock().unwrap_or_else(|e| e.into_inner());
        let out = f(&mut link);
        self.note_state(&link);
        out
    }

    /// This instance speaks for its name in `states` (the hub's, `Hub::spawn_peer`) from now
    /// on: its state now, then each change (`_acpmux/peer_state_changed`). Once it is replaced
    /// or removed, `states` drops what it says.
    pub fn report_states(&self, states: Arc<crate::peer_states::PeerStates>) {
        let link = self.link.lock().unwrap_or_else(|e| e.into_inner());
        states.register(&self.name, self.generation, self.observed(&link));
        *self.states.lock_or_recover() = Some(states);
    }

    /// Called with `link` locked, so the notes go out in the order of the changes.
    fn note_state(&self, link: &Link) {
        // A stopped instance's link going down is not news: its replacement or its removal
        // speaks for the name next.
        if self.stop.load(Ordering::SeqCst) {
            return;
        }
        let Some(states) = self.states.lock_or_recover().clone() else { return };
        states.changed(&self.name, self.generation, self.observed(link));
    }

    fn observed(&self, link: &Link) -> crate::peer_states::Observed {
        let error = self.last_error.lock_or_recover().clone();
        let state = link.state();
        let mut facts = self.facts.lock_or_recover();
        let (whole, since) = facts.observe(state, crate::store::now_ms());
        crate::peer_states::Observed {
            link: whole,
            carrier: facts.live_carrier(state),
            cause: carrier::cause(whole, error.as_deref()),
            since,
            next_retry_at: link.retry_at.filter(|_| !link.is_ready()),
            last_seen: link.last_seen,
            error,
        }
    }

    /// The carrier this attempt runs over (`carrier` while its link is open).
    fn carried_by(&self, by: crate::protocol::peer_state::Carrier) {
        let mut facts = self.facts.lock_or_recover();
        facts.carrier = Some(by);
        // The upgrade went through, so the token was taken.
        facts.refused = false;
    }

    /// The peer refused this attempt's token: the link is `authFailed` until one is taken.
    fn token_refused(&self) {
        self.facts.lock_or_recover().refused = true;
    }

    pub fn state(&self) -> PeerState {
        self.link().state()
    }

    /// Carry the live instance being replaced. Replacing a peer is an explicit retry,
    /// including when that instance never reached it; automatic boot uses the cache path.
    pub fn seed_last_seen(&self, last_seen: Option<u64>) {
        self.retry_immediately.store(true, Ordering::SeqCst);
        self.with_link(|l| l.seed(last_seen));
    }

    /// What its last handshake would have said of attachments: a test's peer that never ran.
    #[cfg(test)]
    pub(crate) fn seed_send_attach(&self, takes: bool) {
        let mut features = self.features.lock_or_recover();
        features.retain(|f| f != crate::attach::FEATURE);
        if takes {
            features.push(crate::attach::FEATURE.to_owned());
        }
    }

    /// What its last handshake listed (`lists`): a test's peer that never ran.
    #[cfg(test)]
    pub(crate) fn seed_features(&self, features: &[&str]) {
        *self.features.lock_or_recover() = features.iter().map(|f| (*f).to_owned()).collect();
    }

    pub(crate) fn seed_cached_link(
        &self,
        last_seen: Option<u64>,
        down_since: Option<u64>,
        next_retry_at: Option<u64>,
    ) {
        self.with_link(|l| {
            l.seed(last_seen);
            l.seed_outage(down_since);
            if l.attempts == 0 && !l.is_ready() {
                l.next_retry_at = next_retry_at;
            }
        });
    }

    /// Restore explicit outage age independently of a possibly old session-cache lastSeen.
    #[cfg(test)]
    pub(crate) fn seed_outage(&self, down_since: Option<u64>) {
        self.with_link(|l| l.seed_outage(down_since));
    }

    /// One failed connect attempt, counted as `finish_link` counts it.
    #[cfg(test)]
    pub(crate) fn count_failed_attempt(&self) {
        self.with_link(|l| l.down(crate::store::now_ms(), self.timings.stable_after));
    }

    /// The refusal for a request while the link is down (`peer_link.rs`).
    pub fn unreachable_error(&self) -> RpcError {
        let error = self.last_error.lock().unwrap_or_else(|e| e.into_inner()).clone();
        crate::peer_link::unreachable_error(
            &self.name,
            &self.link(),
            error.as_deref(),
            crate::store::now_ms(),
        )
    }

    /// Receives every later settled connect attempt.
    pub fn settled(&self) -> tokio::sync::watch::Receiver<u64> {
        self.settled.subscribe()
    }

    /// The hub applied a connect outcome (sessions listed, or the error).
    pub fn mark_settled(&self) {
        self.settled.send_modify(|count| *count += 1);
    }

    /// Every explicit stop/replacement, including one with no connect attempt in flight.
    pub(crate) fn stopped(&self) -> tokio::sync::watch::Receiver<bool> {
        self.stop_changed.subscribe()
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        // Its own tasks stop with it; the hub's shutdown joins them (`close_tasks`).
        self.scope.token().cancel();
        self.stop_changed.send_replace(true);
        self.link_ended();
        // Stores a permit when `serve` is not waiting yet.
        self.stop_signal.notify_one();
        if let Ok(mut t) = self.tunnel.try_lock() {
            if let Some(child) = t.as_mut() {
                let _ = child.start_kill();
            }
            *t = None;
        }
    }

    /// Cancel this peer's own tasks and join them within `within` (the hub's shutdown).
    pub(crate) async fn close_tasks(&self, within: std::time::Duration) -> cmux_scope::CloseReport {
        self.scope.close(within).await
    }

    /// `ssh://user@host[:port]` -> (ssh destination, remote port); None for
    /// any other scheme and for an ssh URL `ssh_target` refuses.
    fn ssh_parts(&self) -> Option<(String, u16)> {
        let t = ssh_target(&self.url).ok()?;
        Some((t.destination, t.port))
    }

    /// Open an `ssh -W` stdio channel to the peer's WebSocket port. The
    /// connection runs over ssh's stdin and stdout, so there is no local port
    /// to wait for: the WebSocket handshake itself says whether it works.
    async fn open_tunnel(
        &self,
    ) -> Result<
        (
            tokio::io::Join<tokio::process::ChildStdout, tokio::process::ChildStdin>,
            u16,
            ssh_errors::Capture,
        ),
        String,
    > {
        let (_, remote_port) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        // Under the tunnel lock, which `stop` takes to end the tunnel: a stop before this point
        // spawns nothing, and one while this holds the lock is seen below once the child is in.
        let mut tunnel = self.tunnel.lock().await;
        if self.stop.load(Ordering::SeqCst) {
            return Err("peer stopped".to_owned());
        }
        let (child, stream, _, errors) = self.spawn_tunnel()?;
        // Replacing the previous channel ends its ssh process.
        *tunnel = Some(child);
        if self.stop.load(Ordering::SeqCst) {
            if let Some(mut child) = tunnel.take() {
                let _ = child.start_kill();
            }
            return Err("peer stopped".to_owned());
        }
        Ok((stream, remote_port, errors))
    }

    /// Spawn an `ssh -W` stdio channel to the peer's WebSocket port, owned by the caller (it
    /// ends when dropped). `open_tunnel` keeps the link's in `tunnel`; a path probe keeps its own.
    #[allow(clippy::type_complexity)]
    fn spawn_tunnel(
        &self,
    ) -> Result<
        (
            tokio::process::Child,
            tokio::io::Join<tokio::process::ChildStdout, tokio::process::ChildStdin>,
            u16,
            ssh_errors::Capture,
        ),
        String,
    > {
        let (host, remote_port) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        let mut child = self
            .ssh_command()
            .args(tunnel_argv(&host, remote_port, self.ssh_connect_secs()))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("spawn ssh: {e}"))?;
        let errors = ssh_errors::Capture::start(child.stderr.take());
        let stdout = child.stdout.take().ok_or_else(|| "ssh stdout".to_owned())?;
        let stdin = child.stdin.take().ok_or_else(|| "ssh stdin".to_owned())?;
        Ok((child, tokio::io::join(stdout, stdin), remote_port, errors))
    }

    /// End the owned ssh tunnel process, if any.
    async fn end_tunnel(&self) {
        if let Some(mut child) = self.tunnel.lock().await.take() {
            let _ = child.start_kill();
        }
    }

    /// ssh's ConnectTimeout for the next attempt. Short, so an attempt sent into a dead network
    /// gives up within a few seconds and the next one starts soon after the network is back;
    /// long while a message wakes the machine (its route may resume a paused one) or after the
    /// host was too slow to send its banner in time (a loaded host; reset once a link is ready).
    fn ssh_connect_secs(&self) -> u64 {
        if self.waking() || self.slow_banner.load(Ordering::SeqCst) {
            SSH_CONNECT_SLOW_SECS
        } else {
            SSH_CONNECT_SECS
        }
    }

    fn note_ssh_failure(&self, reason: Option<&str>) {
        if reason == Some(ssh_errors::BANNER_TIMEOUT) {
            self.slow_banner.store(true, Ordering::SeqCst);
        }
    }

    /// The dashboard token (configured, else the remote daemon's own) and
    /// the remote daemon's peer token of this launch (configured, else none
    /// when the remote has none: an older daemon serves this one as Web),
    /// read over the same ssh access at each connect.
    async fn remote_tokens(&self) -> Result<(String, Option<String>), String> {
        let (host, _) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        if let (Some(t), Some(p)) = (&self.token, &self.peer_token) {
            return Ok((t.clone(), Some(p.clone())));
        }
        let mut child = self
            .ssh_command()
            .args(read_config_argv(&host, self.ssh_connect_secs()))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("read remote config: {e}"))?;
        let errors = ssh_errors::Capture::start(child.stderr.take());
        let read = tokio::time::timeout(self.timings.connect, child.wait_with_output());
        // A stop ends the read (its ssh is killed on drop), so no tunnel follows it.
        let out = tokio::select! {
            out = read => out,
            _ = self.stop_signal.notified() => {
                // Put the permit back for `run` and `serve`, which wait on it too.
                self.stop_signal.notify_one();
                return Err("peer stopped".to_owned());
            }
        };
        let out = out
            .map_err(|_| {
                format!(
                    "reading the remote config timed out after {}s",
                    self.timings.connect.as_secs()
                )
            })?
            .map_err(|e| format!("read remote config: {e}"))?;
        // The read ends with the token `cat`, which fails when there is no
        // token: only an empty answer is a failed ssh.
        if out.stdout.is_empty() && !out.status.success() {
            let reason = errors.finish().await;
            self.note_ssh_failure(reason);
            return Err(ssh_errors::describe(
                format!("ssh to {host} failed ({})", out.status),
                reason,
            ));
        }
        let (config, peer) = split_remote_read(&out.stdout);
        let peer = self.peer_token.clone().or(peer);
        if let Some(t) = &self.token {
            return Ok((t.clone(), peer));
        }
        let remote = remote_daemon_config(config).map_err(|why| match why {
            RemoteConfigError::Unreadable => {
                format!("remote {host} has no readable ~/.acpmux/config.json")
            }
            RemoteConfigError::NoToken => format!("remote {host} config has no websocket token"),
        })?;
        Ok((remote.token, peer))
    }

    /// `remote_tokens`, read again (`TOKEN_REREADS`) while the remote has
    /// no peer token: a daemon that is starting listens a few seconds before
    /// it writes `run/peer.token`, and the one that stopped removed its own.
    /// A connect inside that window would be served as Web, holding every
    /// prompt to the Web's rules until the link next drops. A remote too old
    /// to make a token has none after the rereads and is served as Web.
    async fn remote_tokens_settled(&self) -> Result<(String, Option<String>), String> {
        const STOPPED: &str = "peer stopped";
        if self.stop.load(Ordering::SeqCst) {
            return Err(STOPPED.to_owned());
        }
        let mut tokens = self.remote_tokens().await?;
        for wait in TOKEN_REREADS {
            if tokens.1.is_some() {
                break;
            }
            if !self.reread_wait(wait).await {
                return Err(STOPPED.to_owned());
            }
            tokens = self.remote_tokens().await?;
        }
        self.read_tokens.keep(&tokens);
        Ok(tokens)
    }

    /// The tokens for a connect: the last read's (`peer_tokens.rs`), else a read; true when
    /// they came from the last read, so a refusal reads again.
    async fn connect_tokens(&self) -> Result<(tokens::Tokens, bool), String> {
        if (self.token.is_none() || self.peer_token.is_none())
            && let Some(kept) = self.read_tokens.get()
        {
            return Ok((kept, true));
        }
        Ok((self.remote_tokens_settled().await?, false))
    }

    /// A replacement of the same peer (`Hub::spawn_peer`) skips the read the old one made.
    pub(crate) fn carry_read_tokens(&self, old: &Peer) {
        if old.url == self.url && old.token == self.token && old.peer_token == self.peer_token {
            self.read_tokens.carry(&old.read_tokens);
        }
    }

    /// Sleeps `wait` before a token reread; false, at once, when the peer
    /// stops (before or during it), so no further ssh read is made.
    async fn reread_wait(&self, wait: Duration) -> bool {
        if self.stop.load(Ordering::SeqCst) {
            return false;
        }
        tokio::select! {
            _ = tokio::time::sleep(wait) => {}
            _ = self.stop_signal.notified() => {
                // Put the permit back for `run` and `serve`, which wait on it too.
                self.stop_signal.notify_one();
            }
        }
        !self.stop.load(Ordering::SeqCst)
    }

    /// Why an `ssh://` connection the remote served as Web should connect
    /// again: the remote has a peer token now that this connection did not
    /// present (it restarted between the token read and the handshake, or
    /// had not written its token yet). One read per such connection, and
    /// rereads (`TOKEN_REREADS`) while the remote has no token (it is
    /// restarting, or wrote it after this connection's last read), all
    /// before the link is admitted, so a live link is never torn down for a
    /// late token; None when it was served as a peer, when a read fails, on
    /// stop, or when the remote still has no token or the same one (it
    /// serves this daemon as Web for another reason, and reconnecting would
    /// not change that).
    async fn stale_token(&self) -> Option<String> {
        self.ssh_parts()?;
        let served_as_web =
            self.served_as.lock().unwrap_or_else(|e| e.into_inner()).as_deref() == Some("remote");
        if !served_as_web {
            return None;
        }
        let presented = self.presented.lock().unwrap_or_else(|e| e.into_inner()).clone();
        // What it presented did not make it a peer: the next connect reads again, or takes
        // what this read finds.
        self.read_tokens.forget();
        if self.stop.load(Ordering::SeqCst) {
            return None;
        }
        let (mut token, mut now) = self.remote_tokens().await.ok()?;
        for wait in TOKEN_REREADS {
            if now.is_some() {
                break;
            }
            if !self.reread_wait(wait).await {
                return None;
            }
            (token, now) = self.remote_tokens().await.ok()?;
        }
        if now != presented {
            self.read_tokens.keep(&(token, now.clone()));
        }
        (now.is_some() && now != presented).then(|| {
            "the peer served this daemon as remote, and it has a new peer token; reconnecting"
                .to_owned()
        })
    }

    /// How the peer said at its last handshake that it serves this daemon: `peer`, `remote`
    /// (as a Web client), or None from a peer too old to say.
    pub fn served_as(&self) -> Option<String> {
        self.served_as.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn remote_build(&self) -> Option<String> {
        self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b.clone())
    }

    /// The daemon run the peer named at its last handshake.
    pub fn person_instance(&self) -> Option<String> {
        self.person_instance.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Set before the peer runs (`Hub::spawn_peer`), from its config or lease.
    pub fn set_vm_boundary(&self, on: bool) {
        self.vm_boundary.store(on, Ordering::SeqCst);
    }

    /// Whether this caller opts its remote chains on the peer out of the sandbox.
    pub fn vm_boundary(&self) -> bool {
        self.vm_boundary.load(Ordering::SeqCst)
    }

    /// From its config (`Hub::spawn_peer`, a reload): whether this Mac lends the peer its
    /// GitHub login. Read again for each action, so turning it off holds at once.
    pub fn set_github_broker(&self, on: bool) {
        self.github_broker.store(on, Ordering::SeqCst);
        if !on {
            self.github_revoked.notify_waiters();
        }
    }

    /// Whether this Mac lends the peer GitHub now: its config says so, and the link is one an
    /// on-path machine cannot pose as (`lends_over`).
    pub fn github_broker(&self) -> bool {
        self.github_broker.load(Ordering::SeqCst) && lends_over(&self.url)
    }

    /// The hub's lent cmux sign-in (`github_app_token.rs`).
    pub fn set_github_app(&self, app: Arc<crate::github_app_token::AppLease>) {
        let _ = self.github_app.set(app);
    }

    /// Whether the link `link` (the epoch it was read on) takes a GitHub action now: lent, the
    /// peer not stopped, `link` still the live one, and its handshake finished with the peer
    /// serving this daemon as a peer (not Web), so nothing sent before or around it is.
    fn github_ready(&self, link: u64) -> bool {
        self.github_broker()
            && !self.stop.load(Ordering::SeqCst)
            && self.link_epoch() == link
            && self.github_link.load(Ordering::SeqCst) == link + 1
    }

    /// The peer's daemon asked for a GitHub action (`github_broker.rs`) and `admit_owner` let it
    /// in on `link` (the epoch it was read on): run it, and answer on that link, never on a
    /// later one.
    fn serve_github_action(
        self: &Arc<Self>,
        id: Value,
        params: Value,
        slot: tokio::sync::OwnedSemaphorePermit,
        link: u64,
    ) {
        let me = self.clone();
        let epoch = link;
        // Taken before the task runs and held until its answer is queued: the link does not
        // move to a faster path while it runs (`Peer::switch_due`), for at most the action's
        // own budget.
        let answering = self.answering.start(crate::github_broker::ACTION_BUDGET);
        let scope = &self.scope;
        // The slot is held until the answer is queued, within the request budget: at most
        // `OWNER_SLOTS` of these tasks exist per peer name, across reconnects, even when the link
        // stops reading.
        scope.spawn_until_cancelled("peer-github-action", async move {
            // Lending that ends while it runs (`githubBroker` off, the peer removed, the link
            // ended) stops it: its `gh` is killed (`kill_on_drop`), and a link still up is told.
            let revoked = me.github_revoked.notified();
            tokio::pin!(revoked);
            revoked.as_mut().enable();
            // Lending that ended between the admission and here (the link ended, the peer was
            // stopped or removed, `githubBroker` off) starts nothing.
            if !me.github_ready(epoch) {
                return;
            }
            let app = me.github_app.get().map(Arc::as_ref);
            let reply = tokio::select! {
                reply = crate::github_broker::serve_owner(&me.name, params, app) => reply,
                () = &mut revoked => {
                    let Err(e) = crate::github_broker::admit_owner(&me.name, false, &me.github_slots) else {
                        return;
                    };
                    Err(e)
                }
            };
            let msg = match reply {
                Ok(v) => Message::ok(id, v),
                Err(e) => Message::err(id, e),
            };
            let reply_to = Some(crate::rpc::method::MUX_GITHUB_ACTION);
            if let Ok(line) = msg.bounded_line_replying(reply_to) {
                let frame = Outbound { epoch, key: None, line };
                let _ = tokio::time::timeout(me.timings.request, me.out.send(frame)).await;
            }
            drop(answering);
            drop(slot);
        });
    }

    /// Which connection to the peer this is: it changes when a connection ends or the peer stops.
    pub fn link_epoch(&self) -> u64 {
        self.link_epoch.load(Ordering::SeqCst)
    }

    /// A connection to the peer ended: what the peer kept for it is gone.
    pub(crate) fn link_ended(&self) {
        self.features.lock_or_recover().clear();
        self.link_epoch.fetch_add(1, Ordering::SeqCst);
        self.github_revoked.notify_waiters();
    }

    /// The hub applied a `Connected` notice of this peer: the rows are now those its link listed
    /// at that handshake. A notice no link queued (a test's) stands for the live link.
    pub(crate) fn note_rows_applied(&self) {
        let link = self.listed_links.lock_or_recover().pop_front();
        let link = link.unwrap_or_else(|| self.link_epoch());
        self.rows_link.store(link + 1, Ordering::SeqCst);
    }

    /// The link is ready and the hub applied the session list it sent at its own handshake, so
    /// its notices keep the rows current. A link that dropped and came back reads false until
    /// the new link's list is applied: until then the rows are the link before's.
    pub fn rows_current(&self) -> bool {
        self.ready() && self.rows_link.load(Ordering::SeqCst) == self.link_epoch() + 1
    }

    /// The WebSocket is open and the handshake has not finished.
    pub fn handshaking(&self) -> bool {
        self.open.load(Ordering::SeqCst) && !self.connected.load(Ordering::SeqCst)
    }

    pub fn summary(&self) -> Value {
        let link = self.link();
        let observed = self.observed(&link);
        let (health, health_at) = self.health_summary();
        let paths = self.paths_view();
        json!({
            "name": self.name,
            "url": self.url,
            "connected": self.connected.load(Ordering::SeqCst),
            "handshaking": self.handshaking(),
            "error": self.last_error.lock_or_recover().clone(),
            "remoteVersion": self.remote_version.lock_or_recover().as_ref().map(|(v, _)| v.clone()),
            "remoteBuild": self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b.clone()),
            "localBuild": crate::hub::build(),
            "servedAs": self.served_as.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            "peerTokenWithheld": self.withheld.load(Ordering::SeqCst),
            "canonicalEndpoint": canonical_endpoint(&self.url),
            "outdated": self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b != crate::hub::build()).unwrap_or(false),
            "state": link.state().as_str(),
            "link": observed.link,
            "carrier": observed.carrier,
            "cause": observed.cause,
            "since": observed.since,
            "nextRetryAt": observed.next_retry_at,
            "lastSeen": link.last_seen,
            "downSince": link.down_since,
            "attempts": link.attempts,
            "health": health,
            "healthAt": health_at,
            "paths": paths,
        })
    }

    /// Remember that local clients want this session's stream, so it is
    /// re-attached after a reconnect. True when it was not marked yet; a mark already there is
    /// renewed, since this caller now relies on it.
    pub fn mark_attached(&self, session_id: &str) -> bool {
        // The ticket is taken under the lock, so a later mark always holds a newer one.
        let mut marks = self.attached.lock_or_recover();
        let ticket = self.marks.fetch_add(1, Ordering::SeqCst) + 1;
        let new = marks.insert(session_id.to_owned(), ticket).is_none();
        if new {
            // The stream starts now: its baseline is settled by the attach that follows.
            self.cursors.lock_or_recover().entry(session_id.to_owned()).or_insert(0);
        }
        new
    }

    /// Forget the replay baseline of an attachment whose first baseline request failed. The
    /// mark stays (`attach_hidden`): the next link attaches it without history, which sets a
    /// fresh baseline.
    pub fn clear_attached(&self, session_id: &str) {
        self.replay_highwater.lock_or_recover().remove(session_id);
        self.cursors.lock_or_recover().remove(session_id);
        self.baselined.lock_or_recover().remove(session_id);
    }

    /// The link's own attach of the peer's chat `id` ([`hidden_attach`]), marked already. Its
    /// error goes to the log at warn: a chat whose attach failed got no stream, and said
    /// nothing of why. One the peer refused ([`refuses_attach`]: the chat is gone there, or the
    /// peer takes no such attach) is no longer marked, so no reconnect asks for it again and the
    /// next prompt attaches it anew, unless a client marked it again while this attach was out:
    /// that client relies on the mark. Any other failure (the link dropped, a timeout, a full
    /// queue) keeps the mark, and is tried again on the same link while it stays up
    /// ([`Self::retry_attach`]); the next link's handshake attaches it again in any case. Its
    /// answer, on the link it went out on, is the chat's replay baseline.
    pub async fn attach_hidden(self: &Arc<Self>, id: &str) -> Result<Value, RpcError> {
        let link = self.link_epoch();
        let attached = self.attach_hidden_on(id, link).await;
        if let Err(e) = &attached
            && !refuses_attach(e)
        {
            self.retry_attach(id, link);
        }
        attached
    }

    /// One [`Self::attach_hidden`] on link `link`, with no retry.
    async fn attach_hidden_on(&self, id: &str, link: u64) -> Result<Value, RpcError> {
        let ticket = self.attached.lock_or_recover().get(id).copied();
        let attached = self.request_on(method::MUX_ATTACH, hidden_attach(id), Some(link)).await;
        match &attached {
            Ok(page) if self.link_epoch() == link => self.note_hidden_attach_page(id, page),
            Ok(_) => self.clear_attached(id),
            Err(e) => {
                self.clear_attached(id);
                let refused = refuses_attach(e);
                if refused {
                    let mut marks = self.attached.lock_or_recover();
                    if marks.get(id).copied() == ticket {
                        marks.remove(id);
                    }
                }
                tracing::warn!(peer = %self.name, session = %id, refused, "the peer's chat was not attached, so it streams nothing until it is again: {}", e.message);
            }
        }
        attached
    }

    /// Chat `id`'s attach on link `link` failed without the peer refusing it (it timed out, the
    /// queue was full): it streams nothing on this link, and a Cloud chat's output would just
    /// stop until the next reconnect. It is attached again on the same link, after each of
    /// [`ATTACH_RETRY_AFTER`] in turn, and once it is, its clients are told to read what they
    /// missed ([`Self::tell_reattached`]). It stops when the link ends (the next link's
    /// handshake attaches the chat), when the chat is no longer marked or the peer refuses it,
    /// when another attach gave the chat a stream meanwhile, or after the last retry; the mark
    /// stays for the next link.
    pub(crate) fn retry_attach(self: &Arc<Self>, id: &str, link: u64) {
        if !self.attach_wanted(id, link)
            || !self.attach_retries.lock_or_recover().insert(id.to_owned())
        {
            return;
        }
        let (me, id) = (self.clone(), id.to_owned());
        self.scope.spawn_until_cancelled("peer-attach-retry", async move {
            for (n, after) in ATTACH_RETRY_AFTER.iter().enumerate() {
                tokio::time::sleep(*after).await;
                if !me.attach_wanted(&id, link) {
                    break;
                }
                match me.attach_hidden_on(&id, link).await {
                    Ok(_) => {
                        if me.link_epoch() == link {
                            me.tell_reattached(&id, link).await;
                        }
                        break;
                    }
                    Err(e) if refuses_attach(&e) => break,
                    Err(_) if n + 1 == ATTACH_RETRY_AFTER.len() => {
                        tracing::warn!(peer = %me.name, session = %id, "the peer's chat was not attached after {} retries; the next link attaches it", n + 1);
                    }
                    Err(_) => {}
                }
            }
            me.attach_retries.lock_or_recover().remove(&id);
        });
    }

    /// Whether chat `id`, whose attach on link `link` failed, still needs it: that link is up, the
    /// chat is still marked, and no attach since gave it a stream (which sets its cursor again).
    fn attach_wanted(&self, id: &str, link: u64) -> bool {
        self.link_epoch() == link
            && self.connected.load(Ordering::SeqCst)
            && self.attached.lock_or_recover().contains_key(id)
            && !self.cursors.lock_or_recover().contains_key(id)
    }

    /// Chat `sid` was attached again without history on link `link` ([`REATTACHED_NOTICE`]).
    async fn tell_reattached(&self, sid: &str, link: u64) {
        let notice = PeerNotice::Notification {
            method: REATTACHED_NOTICE.to_owned(),
            params: json!({"sessionId": sid}),
            link,
        };
        let _ = self.notices.send((self.name.clone(), self.generation, notice)).await;
    }

    /// Advance the reconnect cursor from a page returned by `_acpmux/attach`.
    /// The page's `lastSeq` includes records filtered out by `kinds`, so only
    /// the records actually delivered to the client may advance the cursor.
    /// An empty page settles the baseline at its `pageThrough` (it holds every record through
    /// it), so a chat first read with nothing in it is replayed after a reconnect; the caller
    /// passes one only when the page held everything asked for (`server/peer_forward.rs`). A
    /// page that says neither settles nothing.
    pub fn note_attached_page(&self, session_id: &str, page: &Value) {
        let seq = page_max_seq(page).or_else(|| page.get("pageThrough").and_then(Value::as_u64));
        if let Some(seq) = seq {
            self.note_baseline(session_id, seq);
        }
    }

    /// Record an explicit `afterSeq` baseline together with the delivered page.
    /// An empty page still means the caller has already consumed everything
    /// through that sequence.
    pub fn note_attached_page_after(&self, session_id: &str, after: u64, page: &Value) {
        let seq = page_max_seq(page).unwrap_or(after).max(after);
        self.note_baseline(session_id, seq);
    }

    /// A hidden attach deliberately reads no history. Its snapshot is the
    /// stream baseline even when the page has no events. Keep a newer live cursor
    /// if notifications raced the response; never move beyond the peer's snapshot.
    pub fn note_hidden_attach_page(&self, session_id: &str, page: &Value) {
        // Older peers may sample lastSeq after the page. It cannot establish a
        // no-history baseline without risking a live event lost in that interval.
        let Some(seq) = page.get("pageThrough").and_then(Value::as_u64) else {
            return;
        };
        self.note_baseline(session_id, seq);
    }

    /// Move a marked chat's cursor up to `seq`. A fresh client can read ahead while older
    /// clients still need the replay gap, so a chat being replayed keeps its cursor.
    fn note_baseline(&self, session_id: &str, seq: u64) {
        let replay = self.replay_highwater.lock_or_recover();
        if replay.contains_key(session_id)
            || !self.attached.lock_or_recover().contains_key(session_id)
        {
            return;
        }
        self.cursors
            .lock_or_recover()
            .entry(session_id.to_owned())
            .and_modify(|cursor| *cursor = (*cursor).max(seq))
            .or_insert(seq);
        self.baselined.lock_or_recover().insert(session_id.to_owned());
    }

    /// Advance the cursor for a live event sent on this peer link.
    fn note_live(&self, params: &Value) {
        let Some(id) = params.get("sessionId").and_then(Value::as_str) else { return };
        let seq = params
            .get("seq")
            .and_then(Value::as_u64)
            .or_else(|| params.pointer("/_meta/acpmux/seq").and_then(Value::as_u64));
        let Some(seq) = seq else { return };
        if let Some(cursor) = self.cursors.lock_or_recover().get_mut(id) {
            *cursor = (*cursor).max(seq);
        }
    }

    /// This link's deadlines (`peer_link.rs`).
    pub fn timings(&self) -> LinkTimings {
        self.timings
    }

    /// How many requests wait for the peer's answer now.
    pub async fn pending_requests(&self) -> usize {
        self.pending.lock().await.len()
    }

    pub async fn request(&self, m: &str, params: Value) -> Result<Value, RpcError> {
        self.request_on(m, params, None).await
    }

    /// `request` on the link of epoch `epoch` only, when the caller read it before (it labels
    /// what the answer holds with it, `hub/peer_snapshot.rs`): unreachable once that link ended.
    pub async fn request_on(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        // Read before the check: `run` moves the epoch on before it fails what
        // waits, so a request that is registered after that sees the change.
        // One of any link that is bound to its connection goes again on the next link when
        // this one switches paths under it (`resend_switched`).
        let retry = epoch.is_none() && dual::bound(m);
        let epoch = epoch.unwrap_or_else(|| self.link_epoch());
        if !self.connected.load(Ordering::SeqCst) || self.admitting.load(Ordering::SeqCst) {
            return Err(self.unreachable_error());
        }
        self.send_request_with(m, params, Some(epoch), ListKey::None, retry).await
    }

    /// Sends `m` on the link of epoch `epoch` (any link when None), with no check that the
    /// handshake finished: the handshake's own requests go out through here.
    async fn link_request_on(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        self.send_request(m, params, epoch, ListKey::None).await
    }

    /// [`Self::link_request_on`] for the handshake's watch list on link `link`, its
    /// `_acpmux/watch` or a page after it: the reader takes the reply's rows (`watch_key`).
    async fn watch_request_on(&self, m: &str, params: Value, link: u64) -> Result<Value, RpcError> {
        self.send_request(m, params, Some(link), ListKey::Watch).await
    }

    async fn send_request(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
        list: ListKey,
    ) -> Result<Value, RpcError> {
        self.send_request_with(m, params, epoch, list, false).await
    }
}
