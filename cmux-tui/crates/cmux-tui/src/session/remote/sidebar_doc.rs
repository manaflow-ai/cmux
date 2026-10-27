//! The sidebar document over the session connection (`sidebar-doc-v1`).
//!
//! A daemon with the capability owns the workspace order, Pinned and the
//! sections. The TUI reads them as a read model: one `session.events`
//! stream and one `sidebar.get`, both `cmux.protocol/2` lines on the same
//! connection as the control protocol (the daemon dispatches each line by
//! its shape). The reader thread applies each delta batch; a changed order
//! emits `tree-changed` so the app refreshes and draws the new order. A gap,
//! a refused request or the stream's end marks the model stale; the next
//! tree refresh fetches it again on a worker thread, never on the reader.
//!
//! Writes are daemon ops: `sidebar.pin` / `sidebar.unpin` and `sidebar.move`
//! with an anchor item. A daemon without the capability keeps the old path
//! (the control protocol's `move-workspace`, no pin).

use serde_json::Map;

use cmux_tui_core::resource::{PROTOCOL, StreamPublicId};

use super::*;
use crate::session::sidebar_doc::{
    BatchOutcome, ItemRow, PINNED_SECTION_ID, SIDEBAR_DOC_CAPABILITY, SidebarDocModel,
};
use crate::session::tree::TreeView;

/// The neighbors of a workspace's drop slot in the drawn order, by
/// workspace public id. The daemon places the item right before `before`
/// (else right after `after`). `prefer_after`: the pointer is under the row
/// above the slot, so a slot on a section border belongs to `after`'s
/// section, else to `before`'s.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct SidebarDropAnchors {
    pub before: Option<String>,
    pub after: Option<String>,
    pub prefer_after: bool,
}

/// A `sidebar.move` target next to `anchor` (`side`: "before" or "after"),
/// in the anchor's section and group.
fn drop_target(anchor: ItemRow, side: &str) -> Value {
    let mut to = json!({"section": anchor.section});
    to[side] = Value::String(anchor.id);
    if let Some(parent) = anchor.parent {
        to["parent"] = Value::String(parent);
    }
    to
}

/// Stream ends in a row that open the stream again at once.
const MAX_STREAM_RESTARTS: u64 = 3;
/// Past the restart limit, the shortest time between two fallback reads.
const FALLBACK_READ_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Default)]
pub(crate) struct RemoteSidebarDoc {
    model: Mutex<SidebarDocModel>,
    pending: Mutex<HashMap<String, Sender<Value>>>,
    /// The open `session.events` stream.
    stream: Mutex<Option<String>>,
    /// The cursor of the stream's last item: a reopened stream resumes from
    /// it with deltas instead of a full session snapshot.
    cursor: Mutex<Option<Value>>,
    /// A start or refetch worker is running.
    loading: AtomicBool,
    /// A gap was seen: the worker reads the document again.
    dirty: AtomicBool,
    /// Stream ends since the last batch that changed the document. Past the
    /// limit the stream opens again only at the next tree refresh, so a
    /// stream the daemon keeps ending cannot loop.
    stream_restarts: AtomicU64,
    /// When the last fallback `sidebar.get` started (stream ended past the
    /// restart limit): the idle tick reads the document at most this often.
    fallback_read_at: Mutex<Option<Instant>>,
    /// The daemon refused the document on this connection: keep the old
    /// path. A timeout or a closed transport does not set it.
    unavailable: AtomicBool,
    next_id: AtomicU64,
}

/// A poisoned lock still holds a usable read model: a panic elsewhere must
/// not take the TUI down with it.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl RemoteSidebarDoc {
    fn model(&self) -> std::sync::MutexGuard<'_, SidebarDocModel> {
        lock(&self.model)
    }

    fn stream(&self) -> std::sync::MutexGuard<'_, Option<String>> {
        lock(&self.stream)
    }

    fn pending(&self) -> std::sync::MutexGuard<'_, HashMap<String, Sender<Value>>> {
        lock(&self.pending)
    }

    fn cursor(&self) -> std::sync::MutexGuard<'_, Option<Value>> {
        lock(&self.cursor)
    }

    /// Wake every waiting request: the connection is closing.
    pub(super) fn fail_pending(&self) {
        self.pending().clear();
    }
}

/// The daemon answered a request with a structured error: the document is
/// not available on this connection (a timeout or a closed transport is not
/// this).
#[derive(Debug)]
struct Protocol2Refused(String);

impl std::fmt::Display for Protocol2Refused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Protocol2Refused {}

impl RemoteSession {
    /// Whether the TUI draws and edits the daemon's sidebar document.
    pub(crate) fn sidebar_doc_active(&self) -> bool {
        self.supports_capability(SIDEBAR_DOC_CAPABILITY)
            && !self.sidebar_doc.unavailable.load(Ordering::Acquire)
            && self.sidebar_doc.model().is_loaded()
    }

    fn sidebar_doc_wanted(&self) -> bool {
        self.supports_capability(SIDEBAR_DOC_CAPABILITY)
            && !self.sidebar_doc.unavailable.load(Ordering::Acquire)
            // A single-terminal attachment draws no workspace list.
            && self.event_surface_filter.load(Ordering::Acquire) == 0
            && self.subscription_started.load(Ordering::Acquire)
    }

    /// Open the event stream and read the document when it is wanted and
    /// not held. Runs on a worker thread; the caller never waits.
    pub(crate) fn ensure_sidebar_doc(self: &Arc<Self>) {
        self.start_sidebar_doc_worker(false);
    }

    /// `force`: read the document again although one is held (a gap). The
    /// held one stays drawn until the new one is installed.
    fn start_sidebar_doc_worker(self: &Arc<Self>, force: bool) {
        if !self.sidebar_doc_wanted() {
            return;
        }
        if force {
            self.sidebar_doc.dirty.store(true, Ordering::Release);
        } else if self.sidebar_doc.stream().is_some() && self.sidebar_doc.model().is_loaded() {
            return;
        }
        // A running worker reads `dirty` again before it ends.
        if self.sidebar_doc.loading.swap(true, Ordering::AcqRel) {
            return;
        }
        let session = Arc::clone(self);
        let spawned = std::thread::Builder::new().name("sidebar-doc".into()).spawn(move || {
            let doc = &session.sidebar_doc;
            let mut installed = false;
            let result = loop {
                doc.dirty.store(false, Ordering::Release);
                match session.load_sidebar_doc() {
                    Ok(new) => installed |= new,
                    Err(error) => {
                        doc.loading.store(false, Ordering::Release);
                        break Err(error);
                    }
                }
                if doc.dirty.load(Ordering::Acquire) {
                    continue;
                }
                doc.loading.store(false, Ordering::Release);
                // A gap seen after the check above found no worker running.
                if !doc.dirty.load(Ordering::Acquire) || doc.loading.swap(true, Ordering::AcqRel) {
                    break Ok(());
                }
            };
            match result {
                // A new revision: draw its order. The same revision again
                // (a reopened stream) draws nothing new.
                Ok(()) if installed => session.emit(MuxEvent::TreeChanged),
                Ok(()) => {}
                Err(_) if session.request_shutdown_error().is_some() => {}
                Err(error) if error.downcast_ref::<Protocol2Refused>().is_some() => {
                    crate::client_log::warn(
                        "sidebar",
                        &format!(
                            "sidebar document unavailable, keeping the session order: {error:#}"
                        ),
                    );
                    doc.unavailable.store(true, Ordering::Release);
                    let stream = doc.stream().take();
                    if let Some(stream) = stream {
                        session.cancel_sidebar_stream(&stream);
                    }
                    session.emit(MuxEvent::TreeChanged);
                }
                // A timeout: the next tree refresh tries again.
                Err(error) => {
                    crate::client_log::warn("sidebar", &format!("sidebar document: {error:#}"));
                }
            }
        });
        if spawned.is_err() {
            self.sidebar_doc.loading.store(false, Ordering::Release);
        }
    }

    /// The app's loop tick. When the stream ended more often than the
    /// restart limit, the drawn order would stay old until the next tree
    /// refresh: read the document instead (at most once per
    /// `FALLBACK_READ_INTERVAL`), and open the stream again with it.
    pub(crate) fn tick_sidebar_doc(self: &Arc<Self>) {
        // The atomic first: this runs on every turn of the app's loop.
        if self.sidebar_doc.stream_restarts.load(Ordering::Acquire) <= MAX_STREAM_RESTARTS
            || !self.sidebar_doc_wanted()
            || self.sidebar_doc.stream().is_some()
        {
            return;
        }
        let now = Instant::now();
        {
            let mut last = lock(&self.sidebar_doc.fallback_read_at);
            if last.is_some_and(|last| now.duration_since(last) < FALLBACK_READ_INTERVAL) {
                return;
            }
            *last = Some(now);
        }
        self.start_sidebar_doc_worker(true);
    }

    fn load_sidebar_doc(&self) -> anyhow::Result<bool> {
        if self.sidebar_doc.stream().is_none() {
            let stream_id = StreamPublicId::random()
                .map_err(|error| anyhow::anyhow!("cannot allocate a stream id: {error:?}"))?
                .as_str()
                .to_string();
            // Register first: the first items can follow the response at once.
            *self.sidebar_doc.stream() = Some(stream_id.clone());
            let mut fields = Map::new();
            fields.insert("stream_id".into(), Value::String(stream_id.clone()));
            let cursor = self.sidebar_doc.cursor().clone();
            let mut opened = match cursor {
                Some(cursor) => {
                    let mut resumed = fields.clone();
                    resumed.insert("cursor".into(), cursor);
                    self.protocol2_request("session.events", resumed, false)
                }
                None => self.protocol2_request("session.events", fields.clone(), false),
            };
            if opened
                .as_ref()
                .is_err_and(|error| error.downcast_ref::<Protocol2Refused>().is_some())
                && self.sidebar_doc.cursor().take().is_some()
            {
                // A cursor the daemon no longer covers: open with a snapshot.
                opened = self.protocol2_request("session.events", fields, false);
            }
            if let Err(error) = opened {
                *self.sidebar_doc.stream() = None;
                if error.downcast_ref::<Protocol2Refused>().is_none() {
                    // Not answered: the daemon may have opened it anyway.
                    self.cancel_sidebar_stream(&stream_id);
                }
                return Err(error);
            }
        }
        let doc = self.protocol2_request("sidebar.get", Map::new(), false)?;
        self.sidebar_doc.model().load(&doc)
    }

    /// Order `tree`'s workspaces as the document draws them.
    pub(super) fn order_tree_by_sidebar_doc(&self, tree: &mut TreeView) {
        if !self.sidebar_doc_active() {
            return;
        }
        let ranks = self.sidebar_doc.model().workspace_ranks();
        if ranks.is_empty() {
            return;
        }
        tree.order_workspaces_by(|workspace| {
            workspace.resource_id.as_ref().and_then(|id| ranks.get(id.as_str()).copied())
        });
    }

    /// Whether the document has `workspace` in Pinned (`None` without a
    /// document or an item).
    pub(crate) fn sidebar_workspace_pinned(&self, workspace: &str) -> Option<bool> {
        if !self.sidebar_doc_active() {
            return None;
        }
        let model = self.sidebar_doc.model();
        model.workspace_item(workspace).map(|item| item.section == PINNED_SECTION_ID)
    }

    /// The section and group that hold `workspace` (`None` without a
    /// document or an item).
    pub(crate) fn sidebar_workspace_container(
        &self,
        workspace: &str,
    ) -> Option<(String, Option<String>)> {
        if !self.sidebar_doc_active() {
            return None;
        }
        let model = self.sidebar_doc.model();
        model.workspace_item(workspace).map(|item| (item.section.clone(), item.parent.clone()))
    }

    /// `sidebar.pin` or `sidebar.unpin` the item of `workspace`.
    pub(crate) fn sidebar_set_workspace_pinned(
        &self,
        workspace: &str,
        pinned: bool,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(self.sidebar_doc_active(), "the sidebar document is not available");
        let item = self.sidebar_doc.model().workspace_item(workspace).map(|item| item.id.clone());
        let item =
            item.ok_or_else(|| anyhow::anyhow!("the sidebar does not place this workspace yet"))?;
        let mut fields = Map::new();
        fields.insert("items".into(), json!([item]));
        let operation = if pinned { "sidebar.pin" } else { "sidebar.unpin" };
        self.protocol2_request(operation, fields, true).map(|_| ())
    }

    /// `sidebar.move` the item of `workspace` next to an anchor: the drop
    /// lands where it is dropped. A slot inside a section or a group lands
    /// there. A slot on the border of two (the end of Pinned and the start
    /// of the machine list, the end of a group and the next loose row)
    /// belongs to the one the pointer is in (`prefer_after`).
    pub(crate) fn sidebar_move_workspace(
        &self,
        workspace: &str,
        anchors: &SidebarDropAnchors,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(self.sidebar_doc_active(), "the sidebar document is not available");
        let (item, to) = {
            let model = self.sidebar_doc.model();
            let item = model
                .workspace_item(workspace)
                .map(|item| item.id.clone())
                .ok_or_else(|| anyhow::anyhow!("the sidebar does not place this workspace yet"))?;
            let anchor = |workspace: &Option<String>| {
                workspace
                    .as_deref()
                    .and_then(|workspace| model.workspace_item(workspace))
                    .filter(|anchor| anchor.id != item)
                    .cloned()
            };
            let container = |row: &ItemRow| (row.section.clone(), row.parent.clone());
            let to = match (anchor(&anchors.after), anchor(&anchors.before)) {
                (Some(after), Some(before)) if container(&after) == container(&before) => {
                    drop_target(before, "before")
                }
                (Some(after), Some(_)) if anchors.prefer_after => drop_target(after, "after"),
                (Some(_), Some(before)) => drop_target(before, "before"),
                (None, Some(before)) => drop_target(before, "before"),
                (Some(after), None) => drop_target(after, "after"),
                (None, None) => anyhow::bail!("the drop slot has no placed neighbor"),
            };
            (item, to)
        };
        let mut fields = Map::new();
        fields.insert("items".into(), json!([item]));
        fields.insert("to".into(), to);
        self.protocol2_request("sidebar.move", fields, true).map(|_| ())
    }

    /// One `cmux.protocol/2` request on this connection; the answer is the
    /// response's `result`.
    fn protocol2_request(
        &self,
        operation: &str,
        mut fields: Map<String, Value>,
        mutation: bool,
    ) -> anyhow::Result<Value> {
        if let Some(error) = self.request_shutdown_error() {
            return Err(error.into());
        }
        fields.entry("machine").or_insert_with(|| Value::String("current".into()));
        fields.entry("session").or_insert_with(|| Value::String("current".into()));
        let id =
            format!("tui-sidebar-{}", self.sidebar_doc.next_id.fetch_add(1, Ordering::Relaxed));
        let mut request = json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": id,
            "operation": operation,
            "params": fields,
        });
        if mutation {
            let key = StreamPublicId::random().map_err(|error| {
                anyhow::anyhow!("cannot allocate an idempotency key: {error:?}")
            })?;
            request["idempotency_key"] = json!(format!("tui-{}", key.as_str()));
        }
        let message = serde_json::to_string(&request)?;
        let (tx, rx) = channel();
        self.sidebar_doc.pending().insert(id.clone(), tx);
        let forget = || {
            self.sidebar_doc.pending().remove(&id);
        };
        let sequence = match self.interactive_writer.enqueue(message, false) {
            Ok(sequence) => sequence,
            Err(error) => {
                forget();
                return Err(self.classify_transport_error(error).into());
            }
        };
        if let Err(error) = self.wait_for_ordered_write(sequence) {
            forget();
            return Err(self.classify_transport_error(error).into());
        }
        let response =
            match crate::blocking::sync::remote_reply_timeout(&rx, REMOTE_REQUEST_TIMEOUT) {
                Ok(response) => response,
                Err(RecvTimeoutError::Timeout) => {
                    forget();
                    anyhow::bail!("{operation} timed out");
                }
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(match self.request_shutdown_error() {
                        Some(error) => error.into(),
                        None => anyhow::anyhow!("{operation}: the connection closed"),
                    });
                }
            };
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(response.get("result").cloned().unwrap_or(Value::Null));
        }
        let error = response.get("error");
        let code = error.and_then(|error| error.get("code")).and_then(Value::as_str);
        let message = error.and_then(|error| error.get("message")).and_then(Value::as_str);
        Err(Protocol2Refused(format!(
            "{operation} refused: {} {}",
            code.unwrap_or("error"),
            message.unwrap_or("no message")
        ))
        .into())
    }

    /// Release a stream this client no longer reads. Nothing waits for the
    /// answer; items of an unknown stream are ignored.
    fn cancel_sidebar_stream(&self, stream_id: &str) {
        let id =
            format!("tui-sidebar-{}", self.sidebar_doc.next_id.fetch_add(1, Ordering::Relaxed));
        let request = json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": id,
            "operation": "stream.cancel",
            "params": {"machine": "current", "session": "current", "stream": stream_id},
        });
        if let Ok(message) = serde_json::to_string(&request) {
            let _ = self.interactive_writer.enqueue(message, false);
        }
    }

    /// A `cmux.protocol/2` line: a response to one of this connection's
    /// requests, or an item or the end of its event stream.
    pub(super) fn handle_protocol2_line(self: &Arc<Self>, value: Value) {
        match value.get("type").and_then(Value::as_str) {
            Some("response") => {
                let Some(id) = value.get("id").and_then(Value::as_str) else { return };
                if let Some(sender) = self.sidebar_doc.pending().remove(id) {
                    let _ = sender.send(value);
                }
            }
            Some(kind @ ("stream_item" | "stream_end")) => {
                let stream_id = value.get("stream_id").and_then(Value::as_str);
                let ours = {
                    let stream = self.sidebar_doc.stream();
                    stream.is_some() && stream.as_deref() == stream_id
                };
                if !ours {
                    return;
                }
                if let Some(cursor) = value.get("cursor").filter(|cursor| cursor.is_object()) {
                    *self.sidebar_doc.cursor() = Some(cursor.clone());
                }
                if kind == "stream_end" {
                    // A gap or a closed stream: open it again and read the
                    // document; the held one stays drawn meanwhile. Past the
                    // limit the idle tick reads it (`tick_sidebar_doc`).
                    *self.sidebar_doc.stream() = None;
                    let ends = self.sidebar_doc.stream_restarts.fetch_add(1, Ordering::AcqRel) + 1;
                    let reason = value.get("reason").and_then(Value::as_str).unwrap_or("unknown");
                    crate::client_log::log(
                        "INFO",
                        "sidebar",
                        &format!("sidebar event stream ended ({reason}), end {ends} in a row"),
                    );
                    if ends <= MAX_STREAM_RESTARTS {
                        self.start_sidebar_doc_worker(true);
                    }
                    return;
                }
                let item = value.get("item");
                if item.and_then(|item| item.get("kind")).and_then(Value::as_str) != Some("delta") {
                    return;
                }
                let changes = item
                    .and_then(|item| item.get("changes"))
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or_default();
                let outcome = self.sidebar_doc.model().apply_batch(changes);
                if outcome == BatchOutcome::Changed {
                    self.sidebar_doc.stream_restarts.store(0, Ordering::Release);
                }
                match outcome {
                    BatchOutcome::Unchanged => {}
                    BatchOutcome::Changed => self.emit(MuxEvent::TreeChanged),
                    BatchOutcome::Stale => self.start_sidebar_doc_worker(true),
                }
            }
            _ => {}
        }
    }
}
