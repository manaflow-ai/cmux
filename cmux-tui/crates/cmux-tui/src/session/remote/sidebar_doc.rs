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
    BatchOutcome, PINNED_SECTION_ID, SIDEBAR_DOC_CAPABILITY, SidebarDocModel,
};
use crate::session::tree::TreeView;

/// The neighbors of a workspace's drop slot in the drawn order, by
/// workspace public id. The daemon places the item right before `before`
/// (else right after `after`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct SidebarDropAnchors {
    pub before: Option<String>,
    pub after: Option<String>,
}

/// Stream ends in a row that open the stream again at once.
const MAX_STREAM_RESTARTS: u64 = 3;

#[derive(Default)]
pub(crate) struct RemoteSidebarDoc {
    model: Mutex<SidebarDocModel>,
    pending: Mutex<HashMap<String, Sender<Value>>>,
    /// The open `session.events` stream.
    stream: Mutex<Option<String>>,
    /// A start or refetch worker is running.
    loading: AtomicBool,
    /// A gap was seen: the worker reads the document again.
    dirty: AtomicBool,
    /// Stream ends since the last applied batch. Past the limit the stream
    /// opens again only at the next tree refresh, so a stream the daemon
    /// keeps ending cannot loop.
    stream_restarts: AtomicU64,
    /// The daemon refused the protocol on this connection: keep the old path.
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
}

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
                Err(error) => {
                    if session.request_shutdown_error().is_none() {
                        crate::client_log::warn(
                            "sidebar",
                            &format!(
                                "sidebar document unavailable, keeping the session order: {error:#}"
                            ),
                        );
                        doc.unavailable.store(true, Ordering::Release);
                        session.emit(MuxEvent::TreeChanged);
                    }
                }
            }
        });
        if spawned.is_err() {
            self.sidebar_doc.loading.store(false, Ordering::Release);
        }
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
            fields.insert("stream_id".into(), Value::String(stream_id));
            if let Err(error) = self.protocol2_request("session.events", fields, false) {
                *self.sidebar_doc.stream() = None;
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

    /// `sidebar.move` the item of `workspace` next to an anchor. A slot
    /// between two members of a group is in that group, as drawn.
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
            let to = if let Some(anchor) = anchor(&anchors.before) {
                json!({"section": anchor.section, "parent": anchor.parent, "before": anchor.id})
            } else if let Some(anchor) = anchor(&anchors.after) {
                json!({"section": anchor.section, "parent": anchor.parent, "after": anchor.id})
            } else {
                anyhow::bail!("the drop slot has no placed neighbor");
            };
            (item, to)
        };
        let mut to = to;
        if to["parent"].is_null()
            && let Some(object) = to.as_object_mut()
        {
            object.remove("parent");
        }
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
        let response = match rx.recv_timeout(REMOTE_REQUEST_TIMEOUT) {
            Ok(response) => response,
            Err(_) => {
                forget();
                anyhow::bail!("{operation} timed out");
            }
        };
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(response.get("result").cloned().unwrap_or(Value::Null));
        }
        let error = response.get("error");
        let code = error.and_then(|error| error.get("code")).and_then(Value::as_str);
        let message = error.and_then(|error| error.get("message")).and_then(Value::as_str);
        anyhow::bail!(
            "{operation} refused: {} {}",
            code.unwrap_or("error"),
            message.unwrap_or("no message")
        )
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
                if kind == "stream_end" {
                    // A gap or a closed stream: open it again and read the
                    // document; the held one stays drawn meanwhile.
                    *self.sidebar_doc.stream() = None;
                    if self.sidebar_doc.stream_restarts.fetch_add(1, Ordering::AcqRel)
                        < MAX_STREAM_RESTARTS
                    {
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
                if outcome != BatchOutcome::Stale {
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
