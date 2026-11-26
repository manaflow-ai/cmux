//! The running host of `windows-host run`: holds the account's hub socket (online for the
//! account's devices), records viewers waiting for the person, serves one approved session at
//! a time under this desktop's consent (read again for every ticket and every second), and stops
//! a session as soon as its link to the hub drops. linux-host runs its own copy of this loop
//! (src/linux_host/), with the virtual display and the machine credential's renewal.

use super::consent::{self, LocalConsent, Pending};
use super::{requests, TAG};
use crate::Res;
use cmux_hub_host::hub::{now_ms, Hub, HubError};
use cmux_hub_host::net::Message;
use cmux_hub_host::printable;
use cmux_hub_host::session::{self, ServeCommand, Ticket};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const PING_EVERY: Duration = Duration::from_secs(30);

/// How often the running host reads its consent file again.
const CONSENT_EVERY: Duration = Duration::from_secs(1);

/// A session this host serves: its id, its scope (`view`/`full`) and its stop flag.
pub(crate) struct Served {
    pub(crate) id: String,
    pub(crate) scope: String,
    pub(crate) stop: Arc<AtomicBool>,
}

/// The session this host serves now (one at a time; a newer ticket replaces it).
pub(crate) type Current = Arc<Mutex<Option<Served>>>;

/// A running host.
pub struct Host {
    pub hub: Arc<Hub>,
    /// The config directory (`consent.json`).
    pub dir: PathBuf,
    /// The runtime directory (pending requests).
    pub runtime: PathBuf,
    /// The `cmux-rd serve` child every session starts.
    pub serve: ServeCommand,
    /// Whether this host's capture applies a viewer's input; when not, control tickets are
    /// served view only.
    pub applies_input: bool,
    pub(crate) current: Current,
}

impl Host {
    pub fn new(
        hub: Hub,
        dir: PathBuf,
        runtime: PathBuf,
        serve: ServeCommand,
        applies_input: bool,
    ) -> Self {
        Self {
            hub: Arc::new(hub),
            dir,
            runtime,
            serve,
            applies_input,
            current: Arc::new(Mutex::new(None)),
        }
    }

    /// Holds the hub link for good, reconnecting with backoff. Returns only the error `fatal`
    /// maps to a stop (the hub removed this desktop, its anchor ended): restarting cannot fix it.
    pub fn run(
        &self,
        fatal: impl Fn(
            &(dyn std::error::Error + Send + Sync + 'static),
        ) -> Option<Box<dyn std::error::Error + Send + Sync>>,
    ) -> Res<()> {
        let mut backoff = Duration::from_secs(1);
        loop {
            let started = Instant::now();
            let (result, stopped) = hold_link(&self.current, || self.hold_socket());
            if let Some(id) = stopped {
                eprintln!("{TAG}: the hub link dropped; the session it served stopped");
                end_later(&self.hub, &id, "peer_offline");
            }
            if let Err(e) = result {
                if let Some(stop) = fatal(&*e) {
                    return Err(stop);
                }
                eprintln!("{TAG}: hub link: {e}");
            }
            if started.elapsed() > Duration::from_secs(60) {
                backoff = Duration::from_secs(1);
            }
            std::thread::sleep(backoff);
            backoff = (backoff * 2).min(Duration::from_secs(30));
        }
    }

    /// Holds one User DO socket until it closes; handles its pushes.
    fn hold_socket(&self) -> Res<()> {
        let mut ws = self.hub.user_socket()?;
        let mut last_ping = Instant::now();
        let mut last_consent = Instant::now();
        loop {
            if last_consent.elapsed() >= CONSENT_EVERY {
                // Control withdrawn while this runs (linux-host `enable --view-only`, windows-host
                // `enable` without --allow-control): a control session stops now.
                let consent = LocalConsent::load(&self.dir);
                if let Some(id) = withdraw_unconsented(&self.current, consent, self.applies_input) {
                    eprintln!(
                        "{TAG}: this desktop's consent no longer allows the session; stopped"
                    );
                    end_later(&self.hub, &id, "host_stopped");
                }
                last_consent = Instant::now();
            }
            if last_ping.elapsed() >= PING_EVERY {
                // Exactly these bytes: the hub's auto-response matches them.
                ws.send_text(r#"{"type":"ping"}"#)?;
                last_ping = Instant::now();
            }
            match ws.recv(Duration::from_secs(1))? {
                None => {}
                Some(Message::Closed(code, reason)) => {
                    return match code {
                        4001 => Err(HubError {
                            status: 403,
                            code: "device_removed".into(),
                            message: "this desktop was removed from the account".into(),
                        }
                        .into()),
                        4003 => Err(HubError {
                            status: 403,
                            code: "device_removed".into(),
                            message: "this desktop was signed out".into(),
                        }
                        .into()),
                        _ => Err(format!("socket closed ({code} {})", printable(&reason)).into()),
                    };
                }
                Some(Message::Text(text)) => {
                    let Ok(push) = serde_json::from_str::<Value>(&text) else { continue };
                    self.handle_push(&push);
                }
            }
        }
    }

    fn handle_push(&self, push: &Value) {
        let pending = Pending::new(&self.runtime);
        match push["type"].as_str() {
            Some("session.request") => {
                let Ok(mut request) =
                    serde_json::from_value::<consent::Request>(push["session"].clone())
                else {
                    return;
                };
                request.received_ms = now_ms();
                match consent::on_request(&request) {
                    consent::OnRequest::AskThePerson => {
                        eprintln!("{}", requests::ask_line(&request));
                        if let Err(e) = pending.add(request, now_ms()) {
                            eprintln!("{TAG}: request not recorded: {e}");
                        }
                    }
                }
            }
            Some("session.ticket") if push["role"].as_str() == Some("host") => {
                match on_ticket(push, |scope| admit(&self.dir, scope, self.applies_input)) {
                    OnTicket::Serve(ticket, view_only) => self.start_session(ticket, view_only),
                    OnTicket::End(id, reason, why) => {
                        eprintln!("{TAG}: {why}; ended");
                        end_later(&self.hub, &id, reason);
                    }
                    OnTicket::Drop(why) => eprintln!("{TAG}: ticket refused: {why}"),
                }
            }
            Some("session.revoked" | "session.ended" | "session.denied") => {
                let Some(id) = push["sessionId"].as_str() else { return };
                let _ = pending.remove(id, now_ms());
                let guard = self.current.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(served) = guard.as_ref() {
                    if served.id == id {
                        served.stop.store(true, Ordering::SeqCst);
                    }
                }
            }
            _ => {}
        }
    }

    fn start_session(&self, ticket: Ticket, view_only: bool) {
        let stop = Arc::new(AtomicBool::new(false));
        {
            let mut guard = self.current.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(old) = guard.take() {
                // One viewer at a time, the newest. A reattach of the same session replaces its own.
                old.stop.store(true, Ordering::SeqCst);
                if old.id != ticket.session_id {
                    end_later(&self.hub, &old.id, "replaced");
                }
            }
            *guard = Some(Served {
                id: ticket.session_id.clone(),
                scope: ticket.scope.clone(),
                stop: stop.clone(),
            });
        }
        let (hub, args, current) = (self.hub.clone(), self.serve.clone(), self.current.clone());
        let spawned = std::thread::Builder::new().name(format!("{TAG}-session")).spawn(move || {
            eprintln!(
                "{TAG}: serving a {} session for {}",
                if view_only { "view" } else { "control" },
                printable(&ticket.peer_name)
            );
            let ended = session::serve(&hub, &ticket, view_only, &args, &stop);
            eprintln!("{TAG}: session ended: {}", ended.reason);
            if let Some(reason) = ended.tell_hub.as_deref() {
                if let Err(e) = hub.end(&ticket.session_id, reason) {
                    eprintln!("{TAG}: end not sent: {e}");
                }
            }
            let mut guard = current.lock().unwrap_or_else(|e| e.into_inner());
            let ours = |s: &Served| s.id == ticket.session_id && Arc::ptr_eq(&s.stop, &stop);
            if guard.as_ref().is_some_and(ours) {
                *guard = None;
            }
        });
        if let Err(e) = spawned {
            eprintln!("{TAG}: session not started: {e}");
        }
    }
}

/// Stops the session being served, if any; its id.
pub(crate) fn stop_current(current: &Current) -> Option<String> {
    let served = current.lock().unwrap_or_else(|e| e.into_inner()).take()?;
    served.stop.store(true, Ordering::SeqCst);
    Some(served.id)
}

/// Holds one hub link with `hold`; when it ends, for any reason, the session it served stops.
/// The hub does not replay a revocation, an end or sharing turned off that it pushed while
/// the link was down, so a session must not outlive the link that would hear them (fail
/// closed). The result of `hold` and the id of the session stopped.
pub(crate) fn hold_link(
    current: &Current,
    hold: impl FnOnce() -> Res<()>,
) -> (Res<()>, Option<String>) {
    let result = hold();
    (result, stop_current(current))
}

/// How a ticket with `scope` is served under the consent on disk now: `Some(view_only)`,
/// or None when this desktop does not allow it or its consent file cannot be read.
pub(crate) fn admit(dir: &std::path::Path, scope: &str, applies_input: bool) -> Option<bool> {
    match LocalConsent::load(dir) {
        Ok(consent) => consent.serve(scope, applies_input),
        Err(e) => {
            eprintln!("{TAG}: consent unreadable, nothing is served: {e}");
            None
        }
    }
}

/// Stops the session being served when `consent` (read again from disk; an error when it
/// cannot be read) no longer allows its scope; its id.
pub(crate) fn withdraw_unconsented(
    current: &Current,
    consent: Res<LocalConsent>,
    applies_input: bool,
) -> Option<String> {
    let mut guard = current.lock().unwrap_or_else(|e| e.into_inner());
    let allowed = match (&consent, guard.as_ref()) {
        (_, None) => return None,
        (Ok(consent), Some(served)) => consent.serve(&served.scope, applies_input).is_some(),
        (Err(_), Some(_)) => false,
    };
    if allowed {
        return None;
    }
    let served = guard.take()?;
    served.stop.store(true, Ordering::SeqCst);
    Some(served.id)
}

/// What a host `session.ticket` push leads to.
#[derive(Debug)]
pub(crate) enum OnTicket {
    /// Serve it; whether view only.
    Serve(Ticket, bool),
    /// End the session unserved: its id, the reason given to the hub, and why.
    End(String, &'static str, String),
    /// Nothing to serve or end: why.
    Drop(String),
}

/// The answer to a host ticket `push`; `admit` maps its scope to `Some(view_only)` or None
/// when this desktop does not allow it. A ticket that does not parse is ended too, as the
/// Mac host does: the hub approved the session, and only `/end` closes it.
pub(crate) fn on_ticket(push: &Value, admit: impl FnOnce(&str) -> Option<bool>) -> OnTicket {
    let ticket = match Ticket::from_push(push) {
        Ok(t) => t,
        Err(e) => {
            return match push["sessionId"].as_str().filter(|id| !id.is_empty()) {
                Some(id) => OnTicket::End(id.to_owned(), "failed", format!("ticket refused: {e}")),
                None => OnTicket::Drop(e.to_string()),
            }
        }
    };
    match admit(&ticket.scope) {
        Some(view_only) => OnTicket::Serve(ticket, view_only),
        None => OnTicket::End(
            ticket.session_id,
            "failed",
            format!("a {} session is not allowed on this desktop", printable(&ticket.scope)),
        ),
    }
}

/// `/end` off the socket thread.
fn end_later(hub: &Arc<Hub>, id: &str, reason: &'static str) {
    let (hub, id) = (hub.clone(), id.to_owned());
    let _ = std::thread::Builder::new().name(format!("{TAG}-end")).spawn(move || {
        if let Err(e) = hub.end(&id, reason) {
            eprintln!("{TAG}: end not sent: {e}");
        }
    });
}

#[cfg(test)]
#[path = "serving_tests.rs"]
mod tests;
