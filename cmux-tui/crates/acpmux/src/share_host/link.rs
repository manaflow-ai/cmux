//! The share host's hub link, on its own thread (the hub client is blocking): sign in with the
//! machine credential and register this Mac (retried 30 s .. 30 min while the hub refuses), then
//! hold the User DO socket as `cmux-rd linux-host` does (`{"type":"ping"}` every 30 s, reconnect
//! 1 s .. 30 s, 4001/4003 stop it until the Mac is joined again) and act on its pushes. A link
//! that drops stops the shares it served: the hub does not replay a revocation pushed while no
//! socket listened. A daemon that stops leaves them running for the next daemon to adopt.

use super::records::{self, Record};
use super::route::{self, Consent, Route};
use super::state::Shared;
use super::{LOG, helper};
use cmux_hub_host::hub::{Hub, HubError};
use cmux_hub_host::identity::Device;
use cmux_hub_host::net::Message;
use cmux_hub_host::session::Ticket;
use cmux_hub_host::{Res, printable};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

const PING_EVERY: Duration = Duration::from_secs(30);
/// The first and the longest wait before signing in again after the hub refused.
const SIGN_IN_FIRST: Duration = Duration::from_secs(30);
const SIGN_IN_MOST: Duration = Duration::from_secs(30 * 60);
/// The first and the longest wait before reconnecting a dropped socket.
const LINK_FIRST: Duration = Duration::from_secs(1);
const LINK_MOST: Duration = Duration::from_secs(30);

/// Why the link loop ended a hold.
enum Hold {
    /// The daemon is stopping.
    Stopping,
    /// The hub removed or signed out this device: nothing until the Mac is joined again.
    Fatal(String),
    /// The account session could not be renewed: sign in again (with its backoff).
    SignIn(String),
}

/// Runs the link until `stop` (the daemon's scope) is cancelled or the hub removes this device.
pub(crate) fn run(shared: &Arc<Shared>, stop: &CancellationToken) {
    let mut sign_in_wait = SIGN_IN_FIRST;
    loop {
        if stop.is_cancelled() {
            return;
        }
        shared.update_link(|link| link.state = "signing_in");
        if let Err(e) = register(shared) {
            let code = e.downcast_ref::<HubError>().map(|h| h.code.clone());
            tracing::warn!(
                "{LOG}: sign-in failed ({e}); trying again in {} s",
                sign_in_wait.as_secs()
            );
            let at = cmux_hub_host::hub::now_ms()
                .saturating_add(u64::try_from(sign_in_wait.as_millis()).unwrap_or(u64::MAX));
            shared.update_link(|link| {
                link.state = "sign_in_failed";
                link.detail = Some(e.to_string());
                link.code = code;
                link.retry_at_ms = Some(at);
            });
            if sleep(sign_in_wait, stop) {
                return;
            }
            sign_in_wait = sign_in_wait.saturating_mul(2).min(SIGN_IN_MOST);
            continue;
        }
        sign_in_wait = SIGN_IN_FIRST;
        shared.update_link(|link| {
            link.detail = None;
            link.code = None;
            link.retry_at_ms = None;
        });
        send_screen_share(shared, None);
        match hold_while_signed_in(shared, stop) {
            Hold::Stopping => return,
            Hold::Fatal(why) => {
                tracing::warn!("{LOG}: stopped: {why}; join this Mac again to share it");
                shared.update_link(|link| {
                    link.state = "stopped";
                    link.detail = Some(why);
                });
                return;
            }
            Hold::SignIn(why) => {
                tracing::info!("{LOG}: signing in again: {why}");
            }
        }
    }
}

/// Holds the socket, reconnecting it, until it needs a new sign-in, the hub removes this device
/// or the daemon stops.
fn hold_while_signed_in(shared: &Arc<Shared>, stop: &CancellationToken) -> Hold {
    let mut wait = LINK_FIRST;
    loop {
        let started = Instant::now();
        let held = hold_socket(shared, stop);
        shared.update_link(|link| link.state = "offline");
        if stop.is_cancelled() {
            // A handoff: the shares keep running for the next daemon.
            return Hold::Stopping;
        }
        stop_all(shared, "peer_offline");
        let why = match held {
            Ok(()) => "the socket closed".to_owned(),
            Err(e) => {
                if let Some(fatal) = fatal(&*e) {
                    return Hold::Fatal(fatal);
                }
                if needs_sign_in(&*e) {
                    return Hold::SignIn(e.to_string());
                }
                e.to_string()
            }
        };
        tracing::info!("{LOG}: hub link: {why}");
        shared.update_link(|link| link.detail = Some(why));
        if started.elapsed() > Duration::from_secs(60) {
            wait = LINK_FIRST;
        }
        if sleep(wait, stop) {
            return Hold::Stopping;
        }
        wait = wait.saturating_mul(2).min(LINK_MOST);
    }
}

/// Sleeps `wait` in steps of a second; true when `stop` was cancelled meanwhile.
fn sleep(wait: Duration, stop: &CancellationToken) -> bool {
    let started = Instant::now();
    while started.elapsed() < wait {
        if stop.is_cancelled() {
            return true;
        }
        std::thread::sleep(wait.saturating_sub(started.elapsed()).min(Duration::from_secs(1)));
    }
    stop.is_cancelled()
}

/// A hub error that stops the share host until the Mac is joined again.
fn fatal(e: &(dyn std::error::Error + Send + Sync + 'static)) -> Option<String> {
    let h = e.downcast_ref::<HubError>()?;
    matches!(h.code.as_str(), "device_removed").then(|| h.to_string())
}

/// A hub error the machine sign-in answers (or a refused session): sign in again, with the
/// sign-in's backoff.
fn needs_sign_in(e: &(dyn std::error::Error + Send + Sync + 'static)) -> bool {
    e.downcast_ref::<HubError>().is_some_and(|h| {
        h.status == 401
            || matches!(
                h.code.as_str(),
                "account_not_on_hub" | "machine_no_person" | "machine_auth_unavailable"
            )
    })
}

/// Whether the hub refused this device's identity itself (it never registers a removed id
/// again, and a key mismatch means another key holds the id).
fn refuses_identity(e: &(dyn std::error::Error + Send + Sync + 'static)) -> bool {
    e.downcast_ref::<HubError>()
        .is_some_and(|h| matches!(h.code.as_str(), "device_removed" | "device_key_mismatch"))
}

/// Signs in and registers this Mac (`POST /v1/devices` with `shareByJoin`); a new device of the
/// same name when the hub refused the old identity, as the Mac app does.
fn register(shared: &Arc<Shared>) -> Res<()> {
    let share_by_join = helper::share_by_join_here(&shared.home);
    let body = || {
        let mut extra = serde_json::Map::new();
        extra.insert("shareByJoin".into(), Value::Bool(share_by_join));
        extra
    };
    let hub = shared.hub();
    let answer = match hub.register_with("macos", body()) {
        Ok(answer) => answer,
        Err(e) if refuses_identity(&*e) => {
            tracing::warn!("{LOG}: the hub refused this Mac's old device ({e}); registering anew");
            Device::generate(&hub.device.name)?.save(&super::dir(&shared.home))?;
            let renewed = super::machine_hub(&shared.home, false)?;
            let answer = renewed.register_with("macos", body())?;
            shared.set_hub(renewed);
            answer
        }
        Err(e) => return Err(e),
    };
    let sharing = answer.pointer("/device/macScreenShared").and_then(Value::as_bool);
    shared.update_link(|link| {
        link.sharing = sharing.or(link.sharing);
        link.share_by_join = Some(share_by_join);
    });
    Ok(())
}

/// `PUT /v1/devices/:id/screen-share` with the machine's screen-share status, when there is one
/// and it differs from `sent`. The status sent.
fn send_screen_share(shared: &Shared, sent: Option<&Value>) -> Option<Value> {
    let status = helper::status(&shared.home)?;
    if sent == Some(&status) {
        return Some(status);
    }
    let hub = shared.hub();
    let path = format!("/v1/devices/{}/screen-share", hub.device.id);
    let result = hub.call("PUT", &path, Some(&status));
    if let Err(e) = &result {
        tracing::info!("{LOG}: screen-share status not sent: {e}");
    }
    shared.update_link(|link| link.screen_share_sent = Some(result.is_ok()));
    result.ok().map(|_| status)
}

/// Holds one User DO socket until it closes; handles its pushes.
fn hold_socket(shared: &Arc<Shared>, stop: &CancellationToken) -> Res<()> {
    let hub = shared.hub();
    let mut ws = hub.user_socket()?;
    shared.update_link(|link| {
        link.state = "online";
        link.detail = None;
    });
    tracing::info!("{LOG}: online as \"{}\" ({})", printable(&hub.device.name), hub.device.id);
    refresh_devices(shared);
    // Within the hub's offline grace: the shares a daemon left running that ended meanwhile.
    check_adopted(shared);
    let mut sent_status = helper::status(&shared.home);
    let mut last_ping = Instant::now();
    loop {
        if stop.is_cancelled() {
            ws.close();
            return Ok(());
        }
        if last_ping.elapsed() >= PING_EVERY {
            // Exactly these bytes: the hub's auto-response matches them.
            ws.send_text(r#"{"type":"ping"}"#)?;
            last_ping = Instant::now();
            sent_status = send_screen_share(shared, sent_status.as_ref()).or(sent_status);
        }
        match ws.recv(Duration::from_secs(1))? {
            None => {}
            Some(Message::Closed(code, reason)) => {
                let removed = |message: &str| HubError {
                    status: 403,
                    code: "device_removed".into(),
                    message: message.into(),
                };
                return Err(match code {
                    4001 => removed("this Mac was removed from the account").into(),
                    4003 => removed("this Mac was signed out").into(),
                    _ => format!("socket closed ({code} {})", printable(&reason)).into(),
                });
            }
            Some(Message::Text(text)) => handle_push(shared, &text, Consent::read),
        }
    }
}

/// `GET /v1/devices`: the platform of each device, to route tickets.
fn refresh_devices(shared: &Shared) {
    match shared.hub().call("GET", "/v1/devices", None) {
        Ok(devices) => shared.set_devices(&devices),
        Err(e) => tracing::info!("{LOG}: device list not read: {e}"),
    }
}

/// Acts on one push and passes it on to the app's channels (a host ticket with `servedBy`).
pub(crate) fn handle_push(shared: &Arc<Shared>, text: &str, consent: impl FnOnce() -> Consent) {
    let Ok(push) = serde_json::from_str::<Value>(text) else { return };
    let kind = push.get("type").and_then(Value::as_str).unwrap_or_default();
    let session_id = push.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
    match kind {
        "session.ticket" if push.get("role").and_then(Value::as_str) == Some("host") => {
            let decided = decide(shared, &push, consent);
            shared.relay(&route::annotate(&push, decided.served_by()));
            match decided {
                Decided::Serve(view_only) => start_session(shared, &push, &session_id, view_only),
                Decided::App => {}
                Decided::Refused(surface, why) => {
                    tracing::info!("{LOG}: {why}; ended");
                    // The app's sheet asks the person for what is missing (acpmux's record).
                    let _ = crate::cli::cloud_join::record_consent_refusal(surface);
                    // Says why, so the viewer reads it rather than a failed stream (the app's host does too).
                    end_later(shared.hub(), &session_id, "consent_required");
                }
                Decided::End(reason, why) => {
                    tracing::info!("{LOG}: {why}; ended");
                    if !session_id.is_empty() {
                        end_later(shared.hub(), &session_id, reason);
                    }
                }
            }
        }
        "session.revoked" | "session.ended" | "session.denied" => {
            stop_session(shared, &session_id);
            shared.relay(text);
        }
        "devices.changed" => {
            refresh_devices(shared);
            shared.relay(text);
        }
        // Not relayed to the app: the approval is this daemon's to admit.
        super::approval::PUSH => receive_approval(shared, push.clone()),
        _ => shared.relay(text),
    }
}

/// A share approval the hub carried here (`approval.rs`): admitted (and sharing turned on) or
/// refused, audited either way, off the socket thread (it reads the hub's device list and may
/// turn sharing on). Approvals are decided one at a time, so a nonce is taken once.
fn receive_approval(shared: &Arc<Shared>, push: Value) {
    use super::approval;
    let shared = shared.clone();
    let spawned = std::thread::Builder::new().name("share-host-approval".into()).spawn(move || {
        let hub = shared.hub();
        let dir = super::dir(&shared.home);
        let decision = shared.with_seen_approvals(|seen| {
            approval::receive(&*hub, &push, approval::now_secs(), seen, |entry| {
                approval::append_audit(&dir, entry);
            })
        });
        match decision {
            Ok(()) => {
                shared.update_link(|link| link.sharing = Some(true));
                tracing::info!("{LOG}: the owner's device turned sharing on");
            }
            Err(refused) => {
                tracing::info!(
                    "{LOG}: share approval refused: {} {}",
                    refused.code,
                    refused.message
                );
            }
        }
    });
    if let Err(e) = spawned {
        tracing::warn!("{LOG}: the share approval was not read: {e}");
    }
}

/// What a host ticket leads to.
#[derive(Debug, PartialEq)]
enum Decided {
    Serve(bool),
    App,
    /// The consent refuses it: the surface to ask the person for, and why.
    Refused(&'static str, String),
    End(&'static str, String),
}

impl Decided {
    fn served_by(&self) -> &'static str {
        match self {
            Self::App => Route::App.served_by(),
            Self::Serve(_) | Self::Refused(..) | Self::End(..) => "daemon",
        }
    }
}

fn decide(shared: &Shared, push: &Value, consent: impl FnOnce() -> Consent) -> Decided {
    let ticket = match Ticket::from_push(push) {
        Ok(ticket) => ticket,
        // The hub approved the session, and only `/end` closes it, as the Mac host does.
        Err(e) => return Decided::End("failed", format!("ticket refused: {e}")),
    };
    let mut platform = shared.platform_of(&ticket.peer_id);
    if platform.is_none() {
        refresh_devices(shared);
        platform = shared.platform_of(&ticket.peer_id);
    }
    // The person's own device, as the hub authenticated it, needs no consent on this Mac (the
    // default consent is the Labs switch off: everything is allowed); others read it now.
    let consent = if route::own_account(push) { Consent::default() } else { consent() };
    match route::route(&ticket, platform.as_deref(), shared.app_attached(), consent) {
        Route::Daemon { view_only } => Decided::Serve(view_only),
        Route::App => Decided::App,
        Route::End("failed") => Decided::Refused(
            if ticket.scope == "full" { consent.missing() } else { "screen" },
            format!("a {} session is not allowed on this Mac", printable(&ticket.scope)),
        ),
        Route::End(reason) => Decided::End(
            reason,
            format!("{} is not served: {reason}", printable(&ticket.peer_name)),
        ),
    }
}

/// Starts the session process for `push` (`acpmux share-host session`, the push and the view
/// only bit on its stdin), in its own session so it outlives this daemon. A share of the same
/// session already running is stopped first (a reattach replaces its own).
fn start_session(shared: &Shared, push: &Value, session_id: &str, view_only: bool) {
    let dir = records::dir(&shared.home);
    if let Some(old) = records::read(&dir, session_id) {
        old.stop();
    }
    let envelope = json!({"push": push, "viewOnly": view_only});
    match spawn_session(&envelope) {
        Ok(pid) => {
            let kind = if view_only { "view" } else { "control" };
            let viewer = push.pointer("/peer/name").and_then(Value::as_str).unwrap_or("a viewer");
            tracing::info!("{LOG}: serving a {kind} session for {} (pid {pid})", printable(viewer));
        }
        Err(e) => {
            tracing::warn!("{LOG}: the session process did not start: {e}");
            end_later(shared.hub(), session_id, "failed");
        }
    }
}

/// The session process, started with `envelope` on its stdin; its pid.
fn spawn_session(envelope: &Value) -> std::io::Result<u32> {
    use std::io::Write;
    let exe = std::env::current_exe()?;
    let mut child = cmux_process::Command::new(exe)
        .args(["share-host", "session"])
        .stdin(cmux_process::Stdio::piped())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::inherit())
        .new_session()
        .spawn()?;
    child.detach("a share outlives a daemon handoff; its record lets the next daemon adopt it");
    let pid = child.id();
    if let Some(mut stdin) = child.stdin.take() {
        let mut line = envelope.to_string();
        line.push('\n');
        stdin.write_all(line.as_bytes())?;
    }
    // Reaps it whenever it exits while this daemon lives; launchd reaps it after.
    let _ = std::thread::Builder::new().name("share-host-reap".into()).spawn(move || {
        let _ = child.wait();
    });
    Ok(pid)
}

/// Stops session `id`'s process, when one runs.
fn stop_session(shared: &Shared, id: &str) {
    if let Some(record) = records::read(&records::dir(&shared.home), id) {
        record.stop();
    }
}

/// Stops every share (the link dropped), and tells the hub why.
fn stop_all(shared: &Shared, reason: &'static str) {
    let live = records::live(&records::dir(&shared.home), Record::alive);
    if !live.is_empty() {
        tracing::info!("{LOG}: the hub link dropped; the shares it served stopped");
    }
    for record in live {
        if record.stop() {
            end_later(shared.hub(), &record.session_id, reason);
        }
    }
}

/// After the socket connects: `POST /v1/sessions/:id/ice` for each share whose process runs; a
/// session the hub no longer has (`409 session_not_active`) is stopped. Off the socket thread.
fn check_adopted(shared: &Arc<Shared>) {
    let live = records::live(&records::dir(&shared.home), Record::alive);
    if live.is_empty() {
        return;
    }
    let hub = shared.hub();
    let _ = std::thread::Builder::new().name("share-host-adopt".into()).spawn(move || {
        for record in live {
            let path = format!("/v1/sessions/{}/ice", record.session_id);
            match hub.call("POST", &path, Some(&json!({}))) {
                Ok(_) => tracing::info!("{LOG}: session {} adopted", record.session_id),
                Err(e) if not_active(&*e) => {
                    tracing::info!("{LOG}: session {} ended meanwhile; stopped", record.session_id);
                    record.stop();
                }
                Err(e) => tracing::info!("{LOG}: session {} not checked: {e}", record.session_id),
            }
        }
    });
}

/// `409 session_not_active`: the session ended (or never was).
pub(crate) fn not_active(e: &(dyn std::error::Error + Send + Sync + 'static)) -> bool {
    e.downcast_ref::<HubError>().is_some_and(|h| h.status == 409 && h.code == "session_not_active")
}

/// `/end` off the socket thread.
fn end_later(hub: Arc<Hub>, id: &str, reason: &'static str) {
    let id = id.to_owned();
    let _ = std::thread::Builder::new().name("share-host-end".into()).spawn(move || {
        if let Err(e) = hub.end(&id, reason) {
            tracing::info!("{LOG}: end not sent: {e}");
        }
    });
}

#[cfg(test)]
pub(crate) fn decide_for_tests(
    shared: &Shared,
    push: &Value,
    consent: Consent,
) -> (&'static str, Option<bool>) {
    match decide(shared, push, || consent) {
        Decided::Serve(view_only) => ("daemon", Some(view_only)),
        Decided::App => ("app", None),
        Decided::Refused(surface, _) => (surface, None),
        Decided::End(reason, _) => (reason, None),
    }
}
