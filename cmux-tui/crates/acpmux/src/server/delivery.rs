//! Turning a hub record into the notifications one connection is sent.

use super::*;

/// Turn a hub record into client notifications for one connection. It is called only for the
/// records routed to the connection (`interest.rs`): a record a watcher is sent anything for here
/// must be one `interest::watch_hears` names.
pub(super) fn deliver(hub: &Hub, conn: &Conn, ev: HubEvent) {
    // The close of one peer's batch of rows (`hub/list_guard.rs` `send_remote_batch`): only a
    // watcher that asked for batches hears it, in place of the rows' `session_changed`.
    if ev.record.kind == crate::hub::PEER_ROWS_CHANGED {
        if let Some(remote) = &ev.remote
            && conn.peer_row_batches.load(Ordering::SeqCst)
            && conn.watch_all.load(Ordering::SeqCst)
            && !view::a_link(conn)
        {
            let mut params = ev.record.msg.clone();
            params.set("peer", json!(remote.peer));
            params.set("listSeq", json!(ev.list_seq));
            conn.send(&Message::notification(method::MUX_PEER_ROWS_CHANGED, params));
        }
        return;
    }
    conn.controls.event(hub, conn, &ev);
    if ev.record.kind == crate::hub::PEER_LAGGED {
        if conn.sub_opts(&ev.session_id).is_some() {
            conn.send(&Message::notification("_acpmux/lagged", ev.record.msg.clone()));
        }
        return;
    }
    // The key of this chat's row in the queue (`outbound::Row`): its id, qualified for a peer's.
    let row_key = || -> Arc<str> {
        match &ev.remote {
            Some(remote) => remote.qualified_id(&ev.session_id).into(),
            None => Arc::from(ev.session_id.as_str()),
        }
    };
    // A chat's cold archive came or went (`hub/cold_archive.rs`): its row's `coldArchive`; or
    // another unlogged row change (`row_notice`). Not a logged record, so nothing but this
    // notice goes out for it.
    if ev.record.dir == crate::hub::COLD_CHANGED {
        held_rows::flush(hub, conn);
        let attached = conn.sub_opts(&ev.session_id).is_some();
        if (attached || conn.watch_all.load(Ordering::SeqCst))
            && let Ok(s) = hub.resolve(&ev.session_id)
        {
            let full = attached || conn.watch_tools.load(Ordering::SeqCst);
            let mut session =
                if full { hub.session_summary(&s) } else { hub.session_list_summary(&s) };
            if conn.omit_time_breakdown.load(Ordering::SeqCst)
                || (attached && omits_time_breakdown(conn, &ev.session_id))
            {
                requests::without_time_breakdown(&mut session);
            }
            let notice = json!({"sessionId": ev.session_id, "kind": ev.record.kind, "recordKind": ev.record.kind, "seq": s.meta().last_seq, "listSeq": ev.list_seq});
            // A patch names the row it builds on, so it is never replaced in the queue.
            if session_patch::send_row(conn, &ev.session_id, full, &session, notice) {
                return;
            }
            let msg = Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": ev.session_id, "session": session, "kind": ev.record.kind, "recordKind": ev.record.kind, "seq": s.meta().last_seq, "listSeq": ev.list_seq}),
            );
            // An attached chat's row stays among its updates; a watcher's is its latest state.
            let row = if attached { outbound::Row::None } else { outbound::Row::Latest(row_key()) };
            conn.send_row(&msg, row);
        }
        return;
    }
    chats::push_activity(hub, conn, &ev);
    processes::push_update(conn, &ev);
    let rec = &ev.record;
    // Attached peer updates retain the raw wire id, but also identify its owner and the id its
    // row has here (`qualifiedSessionId`), so clients key live transcripts and prompts by the
    // same route as their session rows. A peer daemon's link names it by its own route.
    let routed = |mut params: Value| {
        // A chat that moved to a peer keeps the shape its records had here (`follow.rs`).
        if ev.remote.is_some() && conn.follows.following(&ev.session_id) {
            return params;
        }
        if conn.origin != Origin::Peer
            && let Some(remote) = &ev.remote
        {
            races::peer::qualify_event(&remote.peer, &mut params);
            params.set("qualifiedSessionId", Value::String(remote.qualified_id(&ev.session_id)));
        }
        if let Some(obj) = params.as_object_mut() {
            obj.remove("peer");
            if let Some(remote) = &ev.remote {
                obj.insert("peer".into(), json!(remote.peer));
            }
        }
        params
    };
    let watching = conn.watch_all.load(Ordering::SeqCst);
    let sub = conn.sub_opts(&ev.session_id);
    let attached = sub.is_some();
    if !watching && !attached {
        return;
    }
    if let Some(sub) = &sub
        && rec.dir != "peer"
    {
        // A session message a `session/load` replay already sent here, as its envelope or its
        // notice, is not sent again (`MessageNotices`); an event stream hears only the kinds it
        // asked for, this notice too.
        let message = rec.dir == "mux" && rec.kind == "_acpmux/message";
        let heard = !sub.event_stream || sub.filter.matches_live(rec);
        let repeat = message && heard && {
            let owner = ev.remote.as_ref().map(|r| r.peer.as_str());
            !conn.message_notices.lock_or_recover().live(owner, &ev.session_id, rec.seq)
        };
        // Whether this record went out (or a replay sent it): a peer daemon's link hears of one
        // that did not by its seq alone (`MUX_UNSENT`).
        let mut sent = repeat || sub.event_stream;
        // The agent's stream to a client that draws nothing of the chat while hidden: left out,
        // and read again from its cursor once shown (`SubOpts::quiet_hidden`). Every other record
        // (status, turn ends, asks, the queue) still goes, so its row and its asks stay current.
        let quiet = sub.quiet_hidden
            && sub.hidden
            && rec.dir == "in"
            && rec.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
            && (!sub.event_stream || sub.filter.matches_live(rec))
            && conn.leaves_out_hidden(&ev.session_id, rec.seq);
        if repeat || quiet {
            // Sent by the replay, or left out while hidden.
        } else if sub.event_stream {
            if sub.filter.matches_live(rec) {
                let params = routed(event_value(&ev.session_id, rec));
                conn.send(&conn.chunk_deltas.frame(&ev.session_id, params));
            }
        } else {
            // Agent -> client updates as standard ACP notifications.
            if rec.dir == "in"
                && !rec.kind.ends_with(".replay")
                && let Some(m) = rec.msg.get("method").and_then(Value::as_str)
                && m == method::SESSION_UPDATE
            {
                let message = || {
                    hub.session_update_encodes.fetch_add(1, Ordering::Relaxed);
                    let mut params = rec.msg.get("params").cloned().unwrap_or(json!({}));
                    params.set("sessionId", Value::String(ev.session_id.clone()));
                    crate::hub::merge_mux_meta(
                        &mut params,
                        json!({"seq": rec.seq, "at": rec.at, "kind": rec.kind}),
                    );
                    Message::notification(method::SESSION_UPDATE, routed(params))
                };
                if conn.origin == Origin::Peer {
                    // A peer daemon's link redacts and masks per connection (`send_replying`).
                    conn.send(&message());
                } else {
                    // Every other connection reads the line as it is: built once per record,
                    // shared (`HubEvent::update_line`). None: too large for one frame.
                    let line = ev
                        .update_line
                        .get_or_init(|| message().bounded_line_replying(None).ok().map(Arc::from));
                    match line {
                        Some(line) => conn.send_line(line),
                        None => conn.send(&message()),
                    }
                }
                sent = true;
            }
            if rec.dir == "mux" {
                conn.send(&Message::notification(
                    method::MUX_EVENT,
                    routed(event_value(&ev.session_id, rec)),
                ));
                sent = true;
            }
        }
        // The owner's copy of this chat takes a live record only next to what it covers
        // (`hub/peer_snapshot.rs` `take_record`): without this, the turn's own `session/prompt`
        // stopped it until the next page, so a move during a long turn found a copy without
        // the running turn or the prompts queued behind it.
        if !sent
            && rec.seq > 0
            && conn.origin == Origin::Peer
            && ev.remote.is_none()
            && conn.client_features.hears_any(&[client_features::UNSENT_FEATURE])
        {
            conn.send(&Message::notification(
                method::MUX_UNSENT,
                json!({"sessionId": ev.session_id, "seq": rec.seq}),
            ));
        }
        if message
            && heard
            && !repeat
            && conn.client_features.hears_any(&[crate::capabilities::SESSION_MESSAGES])
        {
            // Routed as the event beside it: a peer's chat id alone may match one here.
            conn.send(&Message::notification(method::MUX_MESSAGE, routed(rec.msg.clone())));
        }
        if rec.dir == "mux" && is_permission_ask(&rec.kind) {
            conn.send(&Message::notification(
                method::MUX_PERMISSION_PENDING,
                routed(permission_pending(&ev.session_id, rec, "attach", ev.remote.is_none())),
            ));
        }
        if let Some(following) = &sub.rows
            && !quiet
            && ev.remote.is_none()
            && let Some((notice, params)) = crate::rows::live(hub, &ev.session_id, rec, following)
        {
            conn.send(&Message::notification(notice, params));
        }
    }
    if watching {
        if let Some(remote) = &ev.remote {
            // A peer's prompt the person must answer, for a unix socket or app
            // watcher that did not attach the session (`hub/person.rs` (c)):
            // never relayed on to a Web client or another peer daemon.
            if rec.kind == crate::hub::PEER_PERMISSION_PENDING {
                if !attached && !conn.origin.web_class() {
                    conn.send_row(
                        &Message::notification(
                            method::MUX_PERMISSION_PENDING,
                            peer_permission_pending(&ev.session_id, rec, remote),
                        ),
                        outbound::Row::After(row_key()),
                    );
                }
                return;
            }
            // Peers already filter to the interesting kinds and send a summary. Another
            // daemon's link hears no change of a row this daemon mirrors: the link drops every
            // such row (`peer.rs` `watch_sessions`), so each change of one peer's row went out on
            // every other peer's link for nothing (24 copies of every change with one daemon's
            // 25 peers, 2026-10-30), and the row's origin hears it from its own. A row of a batch
            // reaches a watcher that asked for batches as the batch's one notice, unless this
            // connection attached the row's chat (`send_remote_batch`, `peer_rows_changed`).
            let batched =
                ev.peer_batch && !attached && conn.peer_row_batches.load(Ordering::SeqCst);
            if rec.dir == "peer" && !view::a_link(conn) && !batched {
                held_rows::flush(hub, conn);
                let sid = remote.summary.session_id().unwrap_or(&ev.session_id);
                // The packed row, parsed for this line only (`RemoteRef::summary`).
                let tools = attached || conn.watch_tools.load(Ordering::SeqCst);
                let mut session: Value = serde_json::from_str(&remote.summary.changed_text(tools))
                    .unwrap_or(Value::Null);
                if conn.omit_time_breakdown.load(Ordering::SeqCst) {
                    requests::without_time_breakdown(&mut session);
                }
                let qualified = remote.qualified_id(&ev.session_id);
                if !attached && conn.leaves_out_row() {
                    // Read again with the list once a chat here shows (`leaves_out_row`).
                    session_patch::forget(conn, &qualified);
                    return;
                }
                if rec.kind == "purged" {
                    session_patch::forget(conn, &qualified);
                } else if session.is_object() {
                    let notice = json!({"sessionId": sid, "qualifiedSessionId": qualified, "kind": rec.kind, "recordKind": rec.kind, "seq": rec.seq, "peer": remote.peer, "listSeq": ev.list_seq});
                    if session_patch::send_row(conn, &qualified, tools, &session, notice) {
                        return;
                    }
                }
                let row =
                    if attached { outbound::Row::None } else { outbound::Row::Latest(row_key()) };
                conn.send_row(
                    &Message::notification(
                        method::MUX_SESSION_CHANGED,
                        json!({"sessionId": sid, "qualifiedSessionId": qualified, "session": session, "kind": rec.kind, "recordKind": rec.kind, "seq": rec.seq, "peer": remote.peer, "listSeq": ev.list_seq}),
                    ),
                    row,
                );
            }
            return;
        }
        if rec.dir == "mux" && rec.kind == "purged" {
            held_rows::flush(hub, conn);
            session_patch::forget(conn, &ev.session_id);
            if !attached && conn.leaves_out_row() {
                return;
            }
            // `replaced`: the same chat came back under this id (`Session::replaced`).
            let mut params = json!({"sessionId": ev.session_id, "session": {"sessionId": ev.session_id}, "kind": "purged", "recordKind": "purged", "seq": rec.seq, "listSeq": ev.list_seq});
            if rec.msg.get("replaced") == Some(&Value::Bool(true)) {
                params.set("replaced", Value::Bool(true));
            }
            // A purge is not passed by a newer row (a `replaced` chat starts over after it).
            conn.send_row(
                &Message::notification(method::MUX_SESSION_CHANGED, params),
                outbound::Row::After(row_key()),
            );
            return;
        }
        // A deferred new chat has no attachment yet. Its command publication must still wake
        // the page's read of that chat's command list, including when skills arrive after creation.
        if rec.dir != "mux" && rec.kind != "available_commands_update" {
            return;
        }
        let Some(kind) = change_kind::session_change_kind(&rec.kind) else { return };
        // A chat's command list still wakes its read (above); its asks still go (below).
        let row_left_out =
            !attached && rec.kind != "available_commands_update" && conn.leaves_out_row();
        // A watcher that is not attached still learns a permission is waiting, after the row
        // that recorded it.
        let ask_pending = || {
            if is_permission_ask(&rec.kind) && !attached {
                conn.send_row(
                    &Message::notification(
                        method::MUX_PERMISSION_PENDING,
                        permission_pending(&ev.session_id, rec, "watch", ev.remote.is_none()),
                    ),
                    outbound::Row::After(row_key()),
                );
            }
        };
        if row_left_out {
            session_patch::forget(conn, &ev.session_id);
            ask_pending();
            return;
        }
        // The row of a record that opens a turn waits behind the turn's first output
        // (`held_rows.rs`); any other row goes after the ones held, in row order.
        if attached && held_rows::opens_a_turn(&rec.kind) {
            conn.held_rows.hold(&ev.session_id, &rec.kind, rec.seq, ev.list_seq);
            return;
        }
        let _held_row = held_rows::flush_sharing(hub, conn, Some(&ev));
        // Built once per record, by the first watcher that sends it, and shared by the others
        // (`HubEvent::row`): with many watchers, each built the whole row again.
        let full = attached || conn.watch_tools.load(Ordering::SeqCst);
        // A full row is mostly its time breakdown (93 of 96 KB on a 2,000-turn chat), sent again
        // on every record of a running turn; a client that draws none shares a row without it.
        let lean = full
            && (conn.omit_time_breakdown.load(Ordering::SeqCst)
                || (attached && omits_time_breakdown(conn, &ev.session_id)));
        let [list_row, full_row, lean_row] = &ev.row.cells;
        let row = if lean {
            lean_row
        } else if full {
            full_row
        } else {
            list_row
        };
        let summary = row.get_or_build(|| {
            let s = hub.resolve(&ev.session_id).ok()?;
            Some(if full {
                let mut summary = hub.session_change_summary(&s, rec.seq);
                if lean {
                    requests::without_time_breakdown(&mut summary);
                }
                summary
            } else {
                hub.session_list_summary(&s)
            })
        });
        if let Some(summary) = summary {
            let notice = json!({"sessionId": ev.session_id, "kind": kind, "recordKind": rec.kind, "seq": rec.seq, "listSeq": ev.list_seq});
            if !session_patch::send_row(conn, &ev.session_id, full, &summary, notice) {
                let row =
                    if attached { outbound::Row::None } else { outbound::Row::Latest(row_key()) };
                conn.send_row(
                    &Message::notification(
                        method::MUX_SESSION_CHANGED,
                        held_rows::row_notice(
                            &ev.session_id,
                            &summary,
                            kind,
                            &rec.kind,
                            rec.seq,
                            ev.list_seq,
                        ),
                    ),
                    row,
                );
            }
        }
        ask_pending();
    }
}
