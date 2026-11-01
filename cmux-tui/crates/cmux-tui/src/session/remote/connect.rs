//! Connecting a remote session: transports, provider authority, and initialization.

use super::*;
use crate::session::sidebar_doc::SIDEBAR_DOC_CAPABILITY;
use cmux_json::JsonSet as _;
use cmux_tui_core::server::OPEN_DEVICE_KINDS_CAPABILITY;
use cmux_tui_core::server::PLACEMENT_SHIFT_CAPABILITY;

impl RemoteSession {
    pub fn connect(path: &Path) -> anyhow::Result<Arc<Self>> {
        Self::connect_path(path, false, true)
    }

    /// Connect to a session socket. A path derived from the session name must
    /// be in this user's private runtime directory and served by this user.
    pub fn connect_session(path: &Path, is_derived: bool) -> anyhow::Result<Arc<Self>> {
        Self::connect_path(path, is_derived, true)
    }

    pub fn connect_session_for_terminal_attach(
        path: &Path,
        is_derived: bool,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_path(path, is_derived, false)
    }

    fn connect_path(path: &Path, is_derived: bool, subscribe: bool) -> anyhow::Result<Arc<Self>> {
        let stream =
            cmux_tui_core::server::connect_session_socket(path, is_derived).map_err(|e| {
                anyhow::anyhow!("cannot connect to session socket {}: {e}", path.display())
            })?;
        if subscribe {
            Self::connect_stream(stream)
        } else {
            Self::connect_stream_with_subscription(stream, false)
        }
    }

    /// Connect over an already-established full-duplex byte stream.
    ///
    /// The cmux protocol is transport-independent JSONL. Keeping stream
    /// establishment outside `RemoteSession` lets clients use a local socket,
    /// an SSH relay, or another authenticated tunnel without teaching the
    /// session and rendering layers about those transports.
    pub fn connect_stream(stream: Box<dyn transport::Stream>) -> anyhow::Result<Arc<Self>> {
        Self::connect_stream_with_subscription(stream, true)
    }

    fn connect_stream_with_subscription(
        stream: Box<dyn transport::Stream>,
        subscribe: bool,
    ) -> anyhow::Result<Arc<Self>> {
        let transport = RemoteTransport::json_lines(stream).map_err(|error| {
            anyhow::anyhow!("cannot configure JSON-lines session transport: {error}")
        })?;
        Self::connect_transport_with_initial_subscription(transport, subscribe)
    }

    pub fn connect_transport(transport: RemoteTransport) -> anyhow::Result<Arc<Self>> {
        Self::connect_transport_with_initial_subscription(transport, true)
    }

    pub(super) fn connect_transport_with_initial_subscription(
        transport: RemoteTransport,
        subscribe: bool,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_transport_with_provider_authority(transport, None, subscribe)
    }

    pub fn connect_provider_transport(
        transport: RemoteTransport,
        authority: BearerToken,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_transport_with_provider_authority(transport, Some(authority), true)
    }

    fn connect_transport_with_provider_authority(
        transport: RemoteTransport,
        provider_workspace_authority: Option<BearerToken>,
        subscribe: bool,
    ) -> anyhow::Result<Arc<Self>> {
        let RemoteTransport { mut reader, writer, abort } = transport;
        let interactive_writer = InteractiveWriter::spawn(writer, abort)
            .map_err(|error| anyhow::anyhow!("cannot start remote interactive writer: {error}"))?;
        let session = Arc::new(RemoteSession {
            interactive_writer,
            api_revision: Mutex::new(None),
            disconnect_state: disconnect::DisconnectCell::default(),
            pending: Mutex::new(PendingRemoteRequests::default()),
            next_id: AtomicU64::new(1),
            attach_progress: AtomicU64::new(0),
            shutdown: AtomicBool::new(false),
            surfaces: Mutex::new(HashMap::new()),
            exited_surfaces: Mutex::new(ExitedSurfaceState::default()),
            surface_leases: Mutex::new(HashMap::new()),
            retired_surfaces: Mutex::new(HashSet::new()),
            #[cfg(test)]
            retire_surface_test_marker: Mutex::new(None),
            tree: Mutex::new(RemoteTreeCache::default()),
            browser_sources: Mutex::new(HashMap::new()),
            tree_refresh: Mutex::new(()),
            tree_stale: AtomicBool::new(true),
            subscription_started: AtomicBool::new(false),
            event_surface_filter: AtomicU64::new(0),
            subscription_recovery: Mutex::new(SubscriptionRecoveryState::default()),
            subscribers: MuxEventBroadcaster::default(),
            primed_subscription: Mutex::new(None),
            frame_dump_dir: std::env::var_os("CMUX_MUX_DEBUG_MIRROR_DUMP").map(PathBuf::from),
            frame_logs: Mutex::new(RemoteFrameLogs::default()),
            surface_overflow_recovery: Mutex::new(HashMap::new()),
            surface_overflow_reconnect_required: AtomicBool::new(false),
            cell_pixel_lifecycle: Mutex::new(()),
            cell_pixels: Mutex::new((8, 16)),
            capabilities: Mutex::new(HashSet::new()),
            size_states: Mutex::new(HashMap::new()),
            provider_workspace_authority,
            provider_workspaces_guarded: AtomicBool::new(false),
            sidebar_doc: sidebar_doc::RemoteSidebarDoc::default(),
        });

        let reader_session = Arc::downgrade(&session);
        std::thread::Builder::new().name("remote-reader".into()).spawn(move || {
            let mut report_progress = |partial: &[u8]| {
                if let Some(session) = reader_session.upgrade() {
                    session.report_read_progress(partial);
                }
            };
            let reason = loop {
                let received = reader.receive_with_progress(&mut report_progress);
                if let Some(reason) = remote_reader_end_reason(&received) {
                    break Some(reason);
                }
                let Ok(Some(mut message)) = received else { unreachable!("end reason handled") };
                if message.len() > REMOTE_SESSION_MESSAGE_MAX_BYTES {
                    break Some(remote_reader_message_too_large(&mut message));
                }
                let Some(session) = reader_session.upgrade() else { break None };
                let translated = session.translate_incoming_line(&message);
                zeroize_string(&mut message);
                let mut message = match translated {
                    Ok(message) => message,
                    Err(error) => {
                        let reason = format!("remote API revision translation failed: {error}");
                        break Some(reason);
                    }
                };
                let value = match serde_json::from_str::<Value>(&message) {
                    Ok(value) => value,
                    Err(error) => {
                        let reason = format!("remote JSON decode failed: {error}");
                        zeroize_string(&mut message);
                        break Some(reason);
                    }
                };
                zeroize_string(&mut message);
                session.handle_line(value);
            };
            // Connection lost: retain the reason before telling the app to quit.
            if let Some(session) = reader_session.upgrade() {
                session.disconnect_transport_with_reason(reason);
                session.emit(MuxEvent::Empty);
            }
        })?;

        if let Err(error) = session.initialize(subscribe) {
            session.disconnect_transport();
            return Err(error);
        }
        // The workspace order, when the daemon owns a sidebar document.
        session.ensure_sidebar_doc();
        Ok(session)
    }

    fn initialize(&self, subscribe: bool) -> anyhow::Result<()> {
        // Identify the endpoint and register this connection before any optional subscription.
        // `revisions` asks for the API revision range and the server's update
        // command; an older server ignores the flag.
        let ident = self.request(json!({"cmd": "identify", "revisions": true}))?;
        validate_remote_identity(&ident)?;
        let api_revision = api_revision::RemoteApiRevision::from_identity(&ident)?;
        self.install_api_revision(api_revision);
        *self.capabilities.lock().unwrap() = identity_capabilities(&ident);
        let mut client_info = json!({"cmd": "set-client-info", "kind": "tui"});
        // A daemon that reports API revisions learns ours, our release and
        // how we were installed, so it can translate for us or name our
        // update command when it refuses (server/api_revision_wire.rs).
        if ident.get("api_revision").is_some() {
            use crate::version_report::{DISTRIBUTION_VERSION, InstallChannel};
            client_info.set(
                "api_revision",
                json!(
                    self.api_revision()
                        .unwrap_or_else(|| cmux_tui_core::server::api_revision_range().0)
                ),
            );
            client_info.set("version", json!(DISTRIBUTION_VERSION));
            client_info.set("install", json!(InstallChannel::current().as_str()));
        }
        if let Some(hostname) = local_hostname() {
            client_info.set("name", json!(hostname));
        }
        let mut negotiated = Vec::new();
        if self.supports_capability(GUARDED_BROWSER_POINTER_CAPABILITY) {
            negotiated.push(GUARDED_BROWSER_POINTER_CAPABILITY);
        }
        if self.supports_capability(VIEW_ATTACHMENT_LEASE_CAPABILITY) {
            negotiated.push(VIEW_ATTACHMENT_LEASE_CAPABILITY);
        }
        if self.supports_capability(VIEW_ATTACHMENT_DETACH_CAPABILITY) {
            negotiated.push(VIEW_ATTACHMENT_DETACH_CAPABILITY);
        }
        if self.supports_capability(CREATION_RECEIPTS_CAPABILITY) {
            negotiated.push(CREATION_RECEIPTS_CAPABILITY);
        }
        if self.supports_capability(CREATION_SELECTOR_FALLBACKS_CAPABILITY) {
            negotiated.push(CREATION_SELECTOR_FALLBACKS_CAPABILITY);
        }
        if self.supports_capability(SHARED_SIZING_CAPABILITY) {
            // Join shared sizing as a terminal client named after this host,
            // like the Mac and iPhone (docs/shared-terminal-sizing.md).
            negotiated.push(SHARED_SIZING_CAPABILITY);
            // The sizing labels read every device kind (an unknown one is
            // "Device"), so the host may send linux and windows as they are.
            if self.supports_capability(OPEN_DEVICE_KINDS_CAPABILITY) {
                negotiated.push(OPEN_DEVICE_KINDS_CAPABILITY);
            }
            // One cmux-tui install per host, so the host name is also the
            // stable device id that keeps two hosts' priority keys apart.
            let host = local_hostname().unwrap_or_else(|| "cmux-tui".to_string());
            client_info.set("device_kind", json!("tui"));
            client_info.set("device_name", json!(host));
            client_info.set("device_id", json!(host));
        }
        // Replays are applied with colors written after them, so the
        // daemon's incomplete sequence must arrive separately.
        if self.supports_capability(TERMINAL_PENDING_SEQUENCE_CAPABILITY) {
            negotiated.push(TERMINAL_PENDING_SEQUENCE_CAPABILITY);
        }
        // The TUI reads the workspace order from the sidebar document, never
        // from `workspace_placement` changes: with `placement-shift-v1` the
        // daemon sends no placement restatement when a new workspace shifts
        // the others.
        if self.supports_capability(SIDEBAR_DOC_CAPABILITY) {
            negotiated.push(SIDEBAR_DOC_CAPABILITY);
        }
        if self.supports_capability(PLACEMENT_SHIFT_CAPABILITY) {
            negotiated.push(PLACEMENT_SHIFT_CAPABILITY);
        }
        if !negotiated.is_empty() {
            client_info.set("capabilities", json!(negotiated));
        }
        self.request(client_info)?;
        if subscribe {
            self.prime_local_subscription();
            if let Err(error) = self.request(self.subscription_request()) {
                self.primed_subscription.lock().unwrap().take();
                return Err(error);
            }
            self.subscription_started.store(true, Ordering::Release);
        }
        Ok(())
    }
}
