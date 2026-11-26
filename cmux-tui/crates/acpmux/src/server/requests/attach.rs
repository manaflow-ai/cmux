//! `_acpmux/attach` (`requests.rs`): a client attaches to a chat and reads its page.

use super::*;

pub(super) async fn attach(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(&params)?)?;
    // The machine's fill, to a client that asked for it (`fill.rs`, RFD 0139).
    super::fill::follow(conn, params.get("fill") == Some(&Value::Bool(true)), &s.id, &s.meta().cwd);
    let hidden = params.get("visible") == Some(&Value::Bool(false));
    // The app's pane draws nothing of a chat it does not show: no stream while hidden.
    // Never a peer daemon's link, which attaches hidden for the people it carries.
    let quiet_hidden =
        params.get("quietHidden") == Some(&Value::Bool(true)) && conn.origin != Origin::Peer;
    if params.get("hold") == Some(&Value::Bool(true)) {
        let filter = hold_attach_filter(&params)?;
        if attach_shows(conn, &params) {
            hub.wake_for(&s, super::trust_gate::for_web(conn.origin, &params), "click");
            if person_asks(conn) {
                hub.release_session_hold_for_person(&s);
            }
        }
        view::attach(
            hub,
            conn,
            &s,
            SubOpts {
                event_stream: true,
                filter,
                hidden,
                idle: !hidden && params.get("attending") == Some(&Value::Bool(false)),
                remote: false,
                rows: None,
                omit_time_breakdown: omits_time_breakdown(&params),
                quiet_hidden,
                left_out: 0,
                left_from: 0,
            },
        );
        let detail = hub.session_detail(&s);
        let last = s.meta().last_seq;
        let presence = hub.presence.snapshot(&s.id);
        let reader = crate::author::author(&params).ok().flatten();
        let read_through = hub.read_through(&s, crate::hub::reader_of(reader.as_ref()));
        let mut reply = json!({
            "session": detail,
            "lastSeq": last,
            "presence": presence,
            "readThrough": read_through,
            "hold": true,
        });
        time_breakdown_gate::apply(&mut reply, &params, conn);
        return Ok(reply);
    }
    // `settled`: the chat's settled view first, read before any log wait; a restart's
    // queue then comes from it (`settled_attach.rs`, cmuxterm-hq#9655).
    let settled = settled_attach::saved(hub, &s, &params);
    let answered_settled = settled.as_ref().is_some_and(|(_, view)| view.is_some());
    // A restart reads the chat logs after its ready line: the queue, turn and status
    // shown here come from this chat's (`hub/log_load.rs`). A chat opened on screen
    // reads it, and its first page below, ahead of agent work (`qos.rs`).
    // A visible page asks for the newest records immediately (`waitLogs:false`); waiting
    // for the full restore here made a restarted long chat blank for tens of seconds.
    // Callers that need authoritative queue/status details keep the old default.
    if !answered_settled && params.get("waitLogs").and_then(Value::as_bool) != Some(false) {
        if hidden {
            hub.session_log(&s).await;
        } else {
            hub.session_log_on_screen(&s).await;
        }
    }
    let filter = crate::hub::EventFilter::parse(params.get("kinds"))?;
    let event_stream = params.get("eventStream").and_then(Value::as_bool).unwrap_or(false);
    // Opening a hibernated chat on screen wakes its agent, unless an earlier daemon
    // hibernated it (`hub/idle.rs` `wake_for`); a CLI's read does not (`attach_shows`).
    if attach_shows(conn, &params) {
        hub.wake_for(&s, super::trust_gate::for_web(conn.origin, &params), "click");
        // The person opening a held chat in the app lets it run (`hub/session_hold.rs`).
        if person_asks(conn) {
            hub.release_session_hold_for_person(&s);
        }
    }
    view::attach(
        hub,
        conn,
        &s,
        SubOpts {
            event_stream,
            filter: filter.clone(),
            hidden,
            idle: !hidden && params.get("attending") == Some(&Value::Bool(false)),
            remote: false,
            rows: None,
            omit_time_breakdown: omits_time_breakdown(&params),
            quiet_hidden,
            left_out: 0,
            left_from: 0,
        },
    );
    let settled_key = match settled {
        Some((_, Some(view))) => {
            let key = view.key.clone();
            if let Some(mut reply) =
                crate::qos::off_worker(|| settled_attach::reply(hub, conn, &s, view))?
            {
                time_breakdown_gate::apply(&mut reply, &params, conn);
                return Ok(reply);
            }
            Some(key)
        }
        Some((key, None)) => Some(key),
        None => None,
    };
    let after = params.get("afterSeq").and_then(Value::as_u64);
    let before = params.get("beforeSeq").and_then(Value::as_u64);
    let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(2000) as usize;
    let max_bytes = Some(crate::hub::page_bytes(&params));
    let detail = hub.session_detail(&s);
    // afterSeq alone pages forward (oldest first); otherwise the page
    // is the newest `limit` records before beforeSeq (or the end).
    let newest = after.is_none() || before.is_some();
    // Read before the page, as `_acpmux/events` does: a page that reads to the log's
    // end holds every record up to it (of the kinds asked), so a client may take
    // the page as covering it.
    let last = s.meta().last_seq;
    // The app's open names its bound: superseded tool output stays out of its page
    // (`store/superseded.rs`); the live stream is unchanged.
    // A phone's open also cuts a tool call's oversized output (`toolOutputMaxBytes`,
    // `hub/tool_output_cut.rs`); live records always go whole.
    let page_filter = filter
        .omitting_superseded(params.get("maxBytes").is_some_and(|b| !b.is_null()))
        .cutting_tool_output(events::tool_output_max(&params));
    let read = || {
        hub.events_page(&s.id, after.unwrap_or(0), before, limit, max_bytes, newest, &page_filter)
    };
    // The page and its turn's prompt (`turn_opener.rs`) read the log from disk: off the
    // runtime's workers, so a hello never waits behind them (`qos::off_worker`).
    let (page, opener) = crate::qos::off_worker(|| {
        let page = if hidden { read() } else { crate::qos::on_screen(read) }?;
        let opener = turn_opener::turn_opener(hub, &s.id, &page);
        anyhow::Ok((page, opener))
    })
    .map_err(|e| RpcError::internal(e.to_string()))?;
    // The newest page holds to the log's end, whether it was asked with no beforeSeq or
    // with one past the end (the app's tail-first attach sends a sentinel): the records
    // after its newest are of kinds it did not ask for. A page of older records, or a
    // forward one with more to read, holds only to its own last record.
    let through = if events::reads_to_end(after.is_some(), before, last, page.has_more) {
        last
    } else {
        events::newest_seq(&page.events)
    };
    hub.lane_report_events_read(conn.caller(), &s.id, &page.events);
    let events: Vec<Value> = events::values(&s.id, page.events);
    // Who has the chat open now (`hub/presence.rs`), this attachment included.
    let presence = hub.presence.snapshot(&s.id);
    // The attaching person's seen cursor (`hub/seen.rs` `read_through`); attaching never
    // moves it.
    let reader = crate::author::author(&params).ok().flatten();
    let read_through = hub.read_through(&s, crate::hub::reader_of(reader.as_ref()));
    let mut reply = json!({"session": detail, "events": events, "hasMore": page.has_more, "lastSeq": last, "pageThrough": through, "presence": presence, "turnOpener": opener, "readThrough": read_through});
    // Asked `settled` and none answered: say so, and write it for the chat's next open.
    if let Some(key) = settled_key {
        reply["settled"] = Value::Null;
        hub.settle_view_for_open(&s, key);
    }
    time_breakdown_gate::apply(&mut reply, &params, conn);
    // The page and its opener each keep a record of up to 14 MiB: together they could
    // pass one message, and the chat then never opened (`hub::fit_reply`).
    crate::hub::fit_reply(&mut reply);
    Ok(reply)
}
