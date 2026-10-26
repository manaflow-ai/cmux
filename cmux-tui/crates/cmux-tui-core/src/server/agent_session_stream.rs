//! Attach replay and live-stream delivery, shared by every native attach caller.
use super::*;
use crate::panic_free::JsonFields;

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
    writer: MessageWriter,
) {
    let sessions = &mux.control_clients.agent_sessions;
    let release = |sessions: &AgentSessions| sessions.lock().reserved.remove(&(client, surface));
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
    let watched = link.call("_acpmux/watch", json!({"enabled": true}), CALL_TIMEOUT);
    let attachment = Arc::new(Attachment {
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
    if let Ok(watched) = &watched {
        attachment
            .follow_children(&agent_session_children::descendant_ids(&attachment.session, watched));
    }
    for pending in page.pointer("/session/pending").and_then(Value::as_array).into_iter().flatten()
    {
        if let Some(permission) = pending.get("permissionId").and_then(Value::as_str) {
            attachment.note_permission(permission);
        }
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
    // A closed tab, or one that now shows another session, stops streaming.
    if same_session && !attachment.tab_current() {
        return attachment.end(Some("detached"));
    }
    match method.as_str() {
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
        "_acpmux/session_changed" if same_session || attachment.follows_change(&params) => {
            if !same_session && !attachment.tab_current() {
                return attachment.end(Some("detached"));
            }
            let event = json!({"event": "agent-session-changed", "surface": attachment.surface, "change": params});
            if attachment.writer.send_stream(&event, &attachment.outbound).is_err() {
                attachment.end(None);
            }
        }
        // Who is in the chat: acpmux sends the whole set on every change, to a client that asked.
        "_acpmux/presence" if same_session && attachment.wants_presence() => {
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
