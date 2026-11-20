use std::sync::mpsc;
use std::time::Instant;

use super::{GlobalArgs, Reads, Route, Start, joined};
use serde_json::{Value, json};

pub(super) fn deadline(start: &Start, began: Instant) -> Option<Instant> {
    let target = start.on.as_deref()?;
    // Waiting for the first reply does not turn automatic placement into a machine name.
    (start.named_machine && target != "here" && (!start.wait || target == "auto"))
        .then(|| began + acpmux::launch_contract::NAMED_START_LIMIT)
}

fn lookup(global: &GlobalArgs, start: &Start, deadline: Option<Instant>) -> Result<Route, Value> {
    let reads = Reads {
        catalog: || super::read_catalog(global),
        signed_in: || super::cloud_start_chat::app_signed_in(global),
        cloud_machines: || super::cloud_start_chat::app_machines(global),
        peers: || crate::cli::agents::chat::chat_peers(global),
    };
    let sources = || joined::Sources {
        hub: || match deadline {
            Some(end) => joined::peers_within(end.saturating_duration_since(Instant::now()))
                .unwrap_or_default(),
            None => joined::hub_peers(),
        },
        rows: || joined::account_rows(global),
    };
    let first = || super::route_start(start, reads);
    if deadline.is_some()
        && !crate::cli::cloud_machines::app_found()
        && let Some(selector) = start.on.as_deref().filter(|selector| {
            !selector.starts_with(joined::PREFIX) && !super::names_cloud(selector)
        })
    {
        let catalog = first();
        if catalog.as_ref().err().and_then(|error| error["code"].as_str())
            == Some("daemon.unreachable")
        {
            return joined::resolve(selector, sources())
                .map_or(catalog, |row| row.map(Route::Joined));
        }
        return super::route_or_joined(Some(selector), || catalog, sources());
    }
    super::route_or_joined(start.on.as_deref(), first, sources())
}

pub(super) fn route(
    global: &GlobalArgs,
    start: Start,
    deadline: Option<Instant>,
) -> Result<(Route, Start), Value> {
    let Some(end) = deadline else { return Ok((lookup(global, &start, None)?, start)) };
    let (send, receive) = mpsc::channel();
    let global = global.clone();
    std::thread::Builder::new()
        .name("chat-machine-lookup".into())
        .spawn(move || { let _ = send.send(find_named(&global, start, end)); })
        .map_err(|error| json!({"code":"chat_target.unavailable", "message":error.to_string(), "retryable":true}))?;
    let (route, start) = receive.recv_timeout(end.saturating_duration_since(Instant::now())).map_err(|_| json!({
        "code":"chat_target.unavailable", "message":"Machine lookup did not finish. No chat was started. Run `cmux machine list` to check the connection.", "retryable":true
    }))??;
    let route = match route {
        Route::Peer(host) => Route::Joined(joined::JoinedMachine {
            id: None,
            name: host.clone(),
            host,
            carrier: joined::Carrier::Peer,
        }),
        other => other,
    };
    Ok((route, start))
}

fn find_named(global: &GlobalArgs, start: Start, end: Instant) -> Result<(Route, Start), Value> {
    find_with(
        start,
        end,
        |left| joined::acp_json(&["machine", "pick", "--json"], None, left),
        |start| lookup(global, start, Some(end)),
    )
}

pub(super) fn find_with(
    mut start: Start,
    end: Instant,
    pick: impl FnOnce(std::time::Duration) -> Result<Value, Value>,
    lookup: impl FnOnce(&Start) -> Result<Route, Value>,
) -> Result<(Route, Start), Value> {
    if start.on.as_deref() == Some("auto") {
        let left = end.saturating_duration_since(Instant::now());
        let verdict = pick(left)?;
        let host = verdict["pick"].as_str().filter(|name| !name.is_empty()).ok_or_else(|| json!({
            "code":"chat_target.unavailable", "message":"Placement selected no machine. Run `cmux acp machine pick` for its reasons.", "details":verdict, "retryable":true
        }))?;
        if verdict["local"].as_bool() == Some(true) {
            return Ok((local_route(host), start));
        }
        start.on = Some(host.to_owned());
    }
    let route = match lookup(&start)? {
        Route::Here => local_route(start.on.as_deref().expect("named machine")),
        route => route,
    };
    Ok((route, start))
}

fn local_route(host: &str) -> Route {
    Route::Joined(joined::JoinedMachine {
        id: None,
        name: host.to_owned(),
        host: host.to_owned(),
        carrier: joined::Carrier::Local,
    })
}
