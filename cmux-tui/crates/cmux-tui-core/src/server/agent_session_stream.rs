//! Attach replay and live-stream delivery, shared by every native attach caller.
use super::*;
use crate::panic_free::JsonFields;
use cmux_json::JsonSet as _;

#[allow(clippy::too_many_arguments)]
pub(super) fn connect_and_attach(
    mux: Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    surface: SurfaceId,
    record_session: String,
    params: Value,
    read_only: bool,
    author: Option<Value>,
    writer: MessageWriter,
) {
    let sessions = &mux.control_clients.agent_sessions;
    let release = |sessions: &AgentSessions| sessions.lock().reserved.remove(&(client, surface));
    let configured_owner = author.is_none()
        && !read_only
        && sessions.cloud_turn.read().unwrap_or_else(|e| e.into_inner()).is_some();
    if configured_owner
        && let Err(refusal) = agent_session_start::reconcile_cloud_scope(&mux, &socket)
    {
        release(sessions);
        refuse(&writer, id, refusal);
        return;
    }
    let newest_first = params.get("afterSeq").is_none() || params.get("beforeSeq").is_some();
    let slot: Arc<Mutex<ReaderSlot>> = Arc::default();
    let reader_slot = slot.clone();
    let reader_mux = Arc::downgrade(&mux);
    let link = AcpmuxLink::connect(&socket, move |inbound| {
        let inbound = match reader_slot.lock().unwrap_or_else(|e| e.into_inner()).hold(inbound) {
            Ok(()) => return,
            Err(inbound) => inbound,
        };
        let attachment = reader_slot.lock().unwrap_or_else(|e| e.into_inner()).attachment.clone();
        let Some(attachment) = attachment else { return };
        deliver(&attachment, inbound);
        if attachment.ended.load(Ordering::Acquire)
            && let Some(mux) = reader_mux.upgrade()
        {
            mux.control_clients.agent_sessions.remove(&attachment);
        }
    });
    let link = match link {
        Ok(link) => link,
        Err(_) => {
            release(sessions);
            refuse(&writer, id, Refusal::Unavailable);
            return;
        }
    };
    let cloud_turn_supported = if configured_owner {
        match turn::support(&link) {
            Ok(supported) => supported,
            Err(refusal) => {
                release(sessions);
                link.close();
                refuse(&writer, id, refusal);
                return;
            }
        }
    } else {
        false
    };
    let page = match link.call("_acpmux/attach", params, CALL_TIMEOUT) {
        Ok(page) => bound_page(page, newest_first),
        Err(error) => {
            release(sessions);
            link.close();
            refuse(&writer, id, Refusal::of(error));
            return;
        }
    };
    let overflow = closed_event(surface, "overflow");
    let Ok(outbound) = writer.start_stream(&overflow) else {
        release(sessions);
        link.close();
        refuse(&writer, id, Refusal::Limit);
        return;
    };
    let resolved =
        page.pointer("/session/sessionId").and_then(Value::as_str).unwrap_or_default().to_string();
    // acpmux resolves an id, a name or a unique prefix of either: only the
    // session the record names exactly (its id or its full name) is the tab's.
    let named = page.pointer("/session/name").and_then(Value::as_str);
    if resolved != record_session && named != Some(record_session.as_str()) {
        release(sessions);
        link.close();
        refuse(&writer, id, Refusal::UnknownTab);
        return;
    }
    slot.lock().unwrap_or_else(|e| e.into_inner()).session = Some(resolved.clone());
    // Session status changes (`_acpmux/session_changed`) come only to
    // watchers; the reader keeps only this session's and its descendants'.
    // The answer (every session's summary) never reaches the client: only
    // the descendants it names are followed from now on.
    let mut watch = json!({"enabled": true});
    if let Some(author) = &author {
        watch.set_path(&["_meta", "acpmux", "author"], author.clone());
    }
    let watched = link.call_whole_list("_acpmux/watch", watch, CALL_TIMEOUT);
    // A list read whole from bad pages would follow only some of the session's descendants,
    // and lose the changes of the rest; the client attaches again instead.
    if let Err(LinkError::BadList(_)) = &watched {
        release(sessions);
        link.close();
        refuse(&writer, id, Refusal::BadList);
        return;
    }
    let mut page = if author.is_some() { without_drafts(page) } else { page };
    // A native owner decides whether to capture from this attachment's actual acpmux,
    // including the first chat after acpmux starts. No discovery runs on identify's thread.
    page["cloud_turn_supported"] = json!(cloud_turn_supported);
    let attachment = Arc::new(Attachment {
        cloud_turn_supported,
        author,
        client,
        surface,
        session: resolved,
        record_session,
        read_only: AtomicBool::new(read_only),
        mux: Arc::downgrade(&mux),
        link: link.clone(),
        writer: writer.clone(),
        outbound,
        calls: AtomicUsize::new(0),
        ended: AtomicBool::new(false),
        permissions: Mutex::default(),
        prompts: Mutex::default(),
        children: Mutex::default(),
    });
    if attachment.author.is_none()
        && let Ok(watched) = &watched
    {
        attachment
            .follow_children(&agent_session_children::descendant_ids(&attachment.session, watched));
    }
    for pending in page.pointer("/session/pending").and_then(Value::as_array).into_iter().flatten()
    {
        if let Some(permission) = pending.get("permissionId").and_then(Value::as_str) {
            attachment.note_permission(permission);
        }
    }
    // A teammate's page is the shared chat's: from this check to the reply no rebind lands
    // (AgentSessions::shared), and a rebind while acpmux answered ends it unseen.
    let shared = attachment.author.is_some().then(|| sessions.shared());
    if shared.is_some() && !attachment.tab_current() {
        drop(shared);
        release(sessions);
        link.close();
        refuse(&writer, id, Refusal::NotShared);
        return;
    }
    {
        let mut state = sessions.lock();
        state.reserved.remove(&(client, surface));
        // The connection ended while connecting: the slot is gone with it.
        if !writer.is_open() {
            drop(state);
            link.close();
            return;
        }
        state.attachments.insert((client, surface), attachment.clone());
    }
    let replied = ok(&writer, id, page);
    drop(shared);
    {
        // The held notifications go out after the reply, in order, before
        // any later one (the reader waits on this lock meanwhile).
        let mut reader = slot.lock().unwrap_or_else(|e| e.into_inner());
        for inbound in std::mem::take(&mut reader.early) {
            deliver(&attachment, inbound);
        }
        if reader.overflowed {
            attachment.end(Some("overflow"));
        }
        reader.attachment = Some(attachment.clone());
    }
    if !replied || attachment.ended.load(Ordering::Acquire) {
        sessions.remove(&attachment);
        attachment.end(None);
    }
}

/// `page` with at most [`MAX_PAGE_BYTES`] of records: a newest-first page
/// drops its oldest records, a forward page its newest; `hasMore` then says
/// more remain.
pub(crate) fn bound_page(mut page: Value, newest_first: bool) -> Value {
    let Some(events) = page.get_mut("events").and_then(Value::as_array_mut) else { return page };
    let sizes: Vec<usize> = events
        .iter()
        .map(|event| serde_json::to_string(event).map_or(0, |text| text.len()))
        .collect();
    let mut total: usize = sizes.iter().sum();
    if total <= MAX_PAGE_BYTES {
        return page;
    }
    let mut keep_from = 0;
    let mut keep_to = events.len();
    while total > MAX_PAGE_BYTES && keep_from < keep_to {
        if newest_first {
            total = total.saturating_sub(sizes.get(keep_from).copied().unwrap_or(0));
            keep_from += 1;
        } else {
            keep_to -= 1;
            total = total.saturating_sub(sizes.get(keep_to).copied().unwrap_or(0));
        }
    }
    let kept: Vec<Value> = events.drain(keep_from..keep_to).collect();
    *events = kept;
    page.insert("hasMore", json!(true));
    page
}

/// A `composer` record: someone's draft text. Kept on the owner's machine.
fn is_draft(record: &Value) -> bool {
    record.get("kind").and_then(Value::as_str) == Some("composer")
}

/// A replay page for a proxied (teammate) attachment: no `composer` records, no `presence`, and
/// the session's summary cut to [`TEAMMATE_SUMMARY`].
pub(crate) fn without_drafts(mut page: Value) -> Value {
    if let Some(object) = page.as_object_mut() {
        object.remove("presence");
    }
    if let Some(events) = page.get_mut("events").and_then(Value::as_array_mut) {
        events.retain(|record| !is_draft(record));
    }
    if let Some(session) = page.get_mut("session") {
        teammate_summary(session);
    }
    page
}

/// What a teammate sees of the shared chat's own summary: what the chat shows (its name, title,
/// status, turn, queue and asks), never where it runs or what it is linked to (folder, parent,
/// children, tags, tools, rules, policy, MCP servers, lane, peer, pull requests).
const TEAMMATE_SUMMARY: &[&str] = &[
    "sessionId",
    "name",
    "harness",
    "status",
    "createdAt",
    "updatedAt",
    "lastSeq",
    "eventCount",
    "turnCount",
    "title",
    "titleSource",
    "preview",
    "lastMessage",
    "queued",
    "queuePaused",
    "steering",
    "turn",
    "queue",
    "pending",
    "pendingPermissions",
    "currentModeId",
    "model",
    "stateSeq",
    "logsLoading",
];

/// Keeps only [`TEAMMATE_SUMMARY`] of a session summary.
pub(crate) fn teammate_summary(session: &mut Value) {
    if let Some(object) = session.as_object_mut() {
        object.retain(|key, _| TEAMMATE_SUMMARY.contains(&key.as_str()));
    }
}

/// What a teammate sees of a `session_changed`: which record changed what, and the summary cut
/// to [`TEAMMATE_SUMMARY`]; never the change's `peer` or any other field acpmux adds later.
pub(crate) fn teammate_change(change: &mut Value) {
    if let Some(object) = change.as_object_mut() {
        object.retain(|key, _| {
            matches!(key.as_str(), "sessionId" | "kind" | "recordKind" | "seq" | "session")
        });
    }
    if let Some(session) = change.get_mut("session") {
        teammate_summary(session);
    }
}

/// One notification or the close from the attachment's acpmux link.
pub(super) fn deliver(attachment: &Attachment, inbound: Inbound) {
    if attachment.ended.load(Ordering::Acquire) {
        return;
    }
    let (method, params) = match inbound {
        Inbound::Closed(reason) => return attachment.end(Some(reason)),
        Inbound::Notification(method, params) => (method, params),
    };
    let same_session = params.get("sessionId").and_then(Value::as_str) == Some(&attachment.session);
    // A teammate's stream holds the rebind lock from its tab check to its write, and stops once
    // the tab shows another chat, whatever the event (AgentSessions::shared).
    let mux = attachment.author.is_some().then(|| attachment.mux.upgrade()).flatten();
    let _shared = mux.as_ref().map(|mux| mux.control_clients.agent_sessions.shared());
    if attachment.author.is_some() && (mux.is_none() || !attachment.tab_current()) {
        return attachment.end(Some("detached"));
    }
    // A link guest's stream stops once its share or the guest ended, however that was noticed.
    if let (Some(mux), Some(author)) = (&mux, &attachment.author)
        && !mux.control_clients.agent_sessions.link_shares().guest_live(author)
    {
        return attachment.end(Some("share_ended"));
    }
    // A closed tab, or one that now shows another session, stops streaming.
    if same_session && !attachment.tab_current() {
        return attachment.end(Some("detached"));
    }
    match method.as_str() {
        // A teammate never sees anyone's unsent text (chat-multiplayer design section 5).
        "_acpmux/event" if same_session && attachment.author.is_some() && is_draft(&params) => {}
        "_acpmux/event" if same_session => {
            let event = json!({"event": "agent-session-record", "surface": attachment.surface, "record": params});
            // Never blocks: a client that does not keep up overflows its
            // stream, which ends with the `overflow` close (the stream's own
            // overflow text), and the client replays from what it holds.
            if attachment.writer.send_stream(&event, &attachment.outbound).is_err() {
                attachment.end(None);
            }
        }
        "_acpmux/permission_pending" if same_session => {
            if let Some(permission) = params.get("permissionId").and_then(Value::as_str) {
                attachment.note_permission(permission);
            }
            let event = json!({"event": "agent-session-permission", "surface": attachment.surface, "request": params});
            if attachment.writer.send_stream(&event, &attachment.outbound).is_err() {
                attachment.end(None);
            }
        }
        // The session's own changes, and its descendants' (`agent-session-children-v1`),
        // while the tab still shows the session.
        "_acpmux/session_changed"
            if same_session
                || (attachment.author.is_none() && attachment.follows_change(&params)) =>
        {
            if !same_session && !attachment.tab_current() {
                return attachment.end(Some("detached"));
            }
            let mut params = params;
            if attachment.author.is_some() {
                teammate_change(&mut params);
            }
            let event = json!({"event": "agent-session-changed", "surface": attachment.surface, "change": params});
            if attachment.writer.send_stream(&event, &attachment.outbound).is_err() {
                attachment.end(None);
            }
        }
        // Who is in the chat: acpmux sends the whole set on every change, to a client that asked.
        // Not to a teammate yet: the set names who else has the chat open.
        "_acpmux/presence"
            if same_session && attachment.author.is_none() && attachment.wants_presence() =>
        {
            let event = json!({"event": "agent-session-presence", "surface": attachment.surface, "presence": params});
            if attachment.writer.send_stream(&event, &attachment.outbound).is_err() {
                attachment.end(None);
            }
        }
        "_acpmux/prompt_accepted" if same_session => {
            let prompt = params.get("promptId").and_then(Value::as_str).unwrap_or_default();
            let slot = attachment.prompts.lock().unwrap_or_else(|e| e.into_inner()).remove(prompt);
            if let Some(slot) = slot {
                let _ = slot.try_send(params);
            }
        }
        "_acpmux/lagged" => attachment.end(Some("lagged")),
        _ => {}
    }
}

#[cfg(test)]
mod draft_tests {
    use super::*;

    #[test]
    fn a_teammate_page_keeps_every_record_but_drafts() {
        let page = json!({"events": [{"seq": 1, "kind": "user_message"},
            {"seq": 2, "kind": "composer", "msg": {"text": "secret"}}, {"seq": 3, "kind": "queued"}]});
        let kept = without_drafts(page);
        let seqs: Vec<u64> =
            kept["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
        assert_eq!(seqs, vec![1, 3]);
        assert!(is_draft(&json!({"kind": "composer"})));
        let page = json!({"events": [], "session": {"sessionId": "s", "name": "chat",
            "status": "running", "cwd": "/Users/owner/secret", "parentId": "p", "startedBy": "p",
            "spawnedBy": "p", "children": 2, "tags": {"lane": "x"}, "tools": [{"name": "Bash"}],
            "rules": true, "mcpServers": [], "pullRequests": ["https://example.com/1"],
            "agentSessionId": "thread", "peer": "other", "turn": {"turnId": "t"}}});
        let session = &without_drafts(page)["session"];
        assert_eq!(
            session,
            &json!({"sessionId": "s", "name": "chat", "status": "running", "turn": {"turnId": "t"}})
        );
        assert!(!is_draft(&json!({"kind": "user_message"})));
        let page = json!({"events": [], "presence": {"sessionId": "s", "participants": [
            {"id": "tailnet:other@example.com", "name": "Other"}]}});
        assert_eq!(without_drafts(page), json!({"events": []}), "no one's presence");
    }
}
