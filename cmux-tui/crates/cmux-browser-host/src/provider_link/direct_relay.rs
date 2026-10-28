//! Agent CDP straight to the Chromium Host.
//!
//! In host mode the app's Chromium tabs run in the Chromium Host, a second
//! process. With a relay link from that host (`relay.hello`, the credential
//! the app derived from this launch's secret), a CEF tab's raw DevTools go
//! host <-> Chromium Host and never through the app's main thread:
//!
//! 1. `open_relay` sends the app `cdp.prepare`; the app marks the tab
//!    agent-driven and makes its page ready (rebuilt, woken, created hidden),
//!    as for `cdp.attach`. Commands wait here meanwhile (bounded, as the
//!    app's own relay queue).
//! 2. The app answers `tab.relay.direct` with the page's browser id and the
//!    link id it gave its Chromium Host (with the credential, so the link's
//!    `relay.hello` names it). When that is the link's id, the host sends
//!    `relay.attach` to the link and the waiting commands after it; from then
//!    on `cdp` frames go both ways on the link. Otherwise (no link, another
//!    app's host) the relay goes through the app as before (`cdp.attach`).
//! 3. Capture commands also reach the app as `cdp.capture`, so a hidden tab
//!    keeps its capture vote; the app holds the agent-ready UI.
//! 4. The link lives as long as the app's provider connection: when that
//!    ends, the link ends too. A Chromium Host that outlives its app
//!    (`browserHost.survivesAppCrash`) dials again with the link id the next
//!    app gives it after that app's `hello.ack`, so an agent drives the same
//!    pages again with no reload. A new link replaces the old one and ends
//!    the old one's relays; their next call prepares the tab again.
//!
//! This is Chrome's remote debugging pipe (content/browser/devtools/
//! devtools_pipe_handler.cc): the pipe is read and written on threads of its
//! own, and only the dispatch to the page's DevTools session runs on the
//! browser's UI thread. Here the "browser" is the Chromium Host, and the
//! embedder (the cmux app) is no hop at all.

use super::*;
use std::collections::HashSet;
use std::sync::Weak;

/// The first raw DevTools id of a relay straight to the Chromium Host: in
/// the shim's raw range (>= 2^30, `cmux_shim_devtools_send`), above the ids
/// the app's own relay counts up from 2^30 (`rawIDCursor`), so a late reply
/// of an earlier relay through the app never matches one of these.
pub(crate) const DIRECT_FIRST_RAW_ID: u64 = 3 << 29;
/// The shim reads a raw id as a C `int`.
const DIRECT_LAST_RAW_ID: u64 = i32::MAX as u64;
/// Commands a relay holds while the app makes its page ready (the app's
/// `RelaySession.queueLimit`).
pub(crate) const PREPARE_QUEUE_LIMIT: usize = 256;

/// The Chromium Host's relay link (`relay.hello` accepted). It ends with the
/// app's provider connection ([`DirectRelays::provider_closed`]) or when a
/// newer link replaces it.
pub(crate) struct RelayLink {
    writer: SharedWriter,
    /// The id the app gave this Chromium Host (`relay.hello`).
    id: String,
    shutdown: Box<dyn Fn() + Send + Sync>,
    /// The provider whose tabs it relays; empty once the link was replaced or
    /// its provider ended, so its reader hands nothing on.
    target: Mutex<Weak<DirectRelays>>,
    /// The link's reader saw its end.
    ended: std::sync::atomic::AtomicBool,
}

impl RelayLink {
    fn target(&self) -> Option<Arc<DirectRelays>> {
        self.target.lock().unwrap_or_else(PoisonError::into_inner).upgrade()
    }

    fn retarget(&self, target: Weak<DirectRelays>) {
        *self.target.lock().unwrap_or_else(PoisonError::into_inner) = target;
    }

    fn is_ended(&self) -> bool {
        self.ended.load(Ordering::Acquire)
    }

    fn write(&self, frame: &Frame) -> std::io::Result<()> {
        write_frame(&mut *self.writer.lock().unwrap_or_else(PoisonError::into_inner), frame)
            .map_err(|error| std::io::Error::other(error.to_string()))
    }

    /// Whether the app's answer names this link's Chromium Host.
    fn serves(&self, link: Option<&str>) -> bool {
        link == Some(self.id.as_str())
    }
}

/// Where one relay's messages go.
enum Route {
    /// `cdp.prepare` sent; commands wait for the app's answer.
    Preparing(Vec<String>),
    /// Straight to the Chromium Host.
    Host(Arc<RelayLink>),
    /// Through the app (`cdp.attach`): no link served the tab's host.
    App,
    /// The page could not be made ready, or the relay ended.
    Closed(String),
}

/// One relay's route, shared by its wire and the readers.
pub(crate) struct DirectRoute {
    target_id: String,
    app: SharedWriter,
    route: Mutex<Route>,
    /// Screenshot ids sent to the host and not answered: the app holds a
    /// capture vote for each.
    screenshots: Mutex<HashSet<u64>>,
}

impl DirectRoute {
    fn new(target_id: &str, app: SharedWriter) -> Arc<DirectRoute> {
        Arc::new(DirectRoute {
            target_id: target_id.to_owned(),
            app,
            route: Mutex::new(Route::Preparing(Vec::new())),
            screenshots: Mutex::default(),
        })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, Route> {
        self.route.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn write_app(&self, frame: &Frame) -> std::io::Result<()> {
        write_frame(&mut *self.app.lock().unwrap_or_else(PoisonError::into_inner), frame)
            .map_err(|error| std::io::Error::other(error.to_string()))
    }

    fn cdp(&self, message: &str) -> Frame {
        Frame::Cdp { target_id: self.target_id.clone(), message: message.to_owned() }
    }

    /// One command of the relay's connection. The route stays locked while
    /// it is written, so a flush of the waiting commands and a new command
    /// never pass each other.
    pub(crate) fn send(&self, message: &str) -> std::io::Result<()> {
        let mut route = self.state();
        match &mut *route {
            Route::Preparing(queued) => {
                if queued.len() >= PREPARE_QUEUE_LIMIT {
                    return Err(std::io::Error::other(
                        "too many commands while the tab's page starts",
                    ));
                }
                queued.push(message.to_owned());
                Ok(())
            }
            Route::Host(link) => self.to_host(link, message),
            Route::App => self.write_app(&self.cdp(message)),
            Route::Closed(reason) => Err(std::io::Error::other(reason.clone())),
        }
    }

    /// A command to the Chromium Host; a capture command tells the app
    /// first, so its vote is taken before the page can answer.
    fn to_host(&self, link: &RelayLink, message: &str) -> std::io::Result<()> {
        if let Some(capture) = CaptureCommand::of(message) {
            let frame = match capture {
                CaptureCommand::Screenshot(id) => {
                    self.screenshots.lock().unwrap_or_else(PoisonError::into_inner).insert(id);
                    self.capture_frame("screenshot", true, Some(id))
                }
                CaptureCommand::Screencast(active) => {
                    self.capture_frame("screencast", active, None)
                }
            };
            self.write_app(&frame)?;
        }
        link.write(&self.cdp(message))
    }

    fn capture_frame(&self, capture: &str, active: bool, id: Option<u64>) -> Frame {
        Frame::CdpCapture {
            target_id: self.target_id.clone(),
            capture: capture.to_owned(),
            active,
            id,
        }
    }

    /// A message from the Chromium Host: a screenshot's reply ends its vote.
    fn inbound(&self, message: &str) {
        let mut screenshots = self.screenshots.lock().unwrap_or_else(PoisonError::into_inner);
        if screenshots.is_empty() {
            return;
        }
        let Some(id) = reply_id(message) else { return };
        if screenshots.remove(&id) {
            drop(screenshots);
            let _ = self.write_app(&self.capture_frame("screenshot", false, Some(id)));
        }
    }

    /// Whether the relay goes over `link`.
    fn on_link(&self, link: &Arc<RelayLink>) -> bool {
        matches!(&*self.state(), Route::Host(on) if Arc::ptr_eq(on, link))
    }

    fn close(&self, reason: &str) {
        let mut route = self.state();
        if let Route::Host(link) = &*route {
            let _ = link.write(&Frame::RelayDetach { target_id: self.target_id.clone() });
        }
        *route = Route::Closed(reason.to_owned());
    }
}

/// A command whose page capture the app votes for (`CDPCaptureCommand`).
enum CaptureCommand {
    Screenshot(u64),
    Screencast(bool),
}

impl CaptureCommand {
    /// [`CdpConnection`] writes `{"id":..,"method":"..",..}` with sorted
    /// keys: a plain text check passes every other command without a parse.
    fn of(message: &str) -> Option<CaptureCommand> {
        if message.contains(r#""method":"Page.captureScreenshot""#) {
            return reply_id(message).map(CaptureCommand::Screenshot);
        }
        if message.contains(r#""method":"Page.startScreencast""#) {
            return Some(CaptureCommand::Screencast(true));
        }
        if message.contains(r#""method":"Page.stopScreencast""#) {
            return Some(CaptureCommand::Screencast(false));
        }
        None
    }
}

/// The top-level integer `id` of a CDP message.
fn reply_id(message: &str) -> Option<u64> {
    #[derive(serde::Deserialize)]
    struct Id {
        id: Option<u64>,
    }
    serde_json::from_str::<Id>(message).ok()?.id
}

/// The provider's relays straight to the Chromium Host.
pub(crate) struct DirectRelays {
    app: SharedWriter,
    relays: Relays,
    cef_tabs: CefTabs,
    link: Mutex<Option<Arc<RelayLink>>>,
    routes: Mutex<HashMap<String, Arc<DirectRoute>>>,
    /// The next raw id per tab, kept across relays (as the app's
    /// `rawIDCursor`): a late reply of an old relay finds no call.
    cursors: Mutex<HashMap<String, u64>>,
}

impl DirectRelays {
    pub(super) fn new(app: SharedWriter, relays: Relays, cef_tabs: CefTabs) -> Arc<DirectRelays> {
        Arc::new(DirectRelays {
            app,
            relays,
            cef_tabs,
            link: Mutex::default(),
            routes: Mutex::default(),
            cursors: Mutex::default(),
        })
    }

    fn current_link(&self) -> Option<Arc<RelayLink>> {
        self.link
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .filter(|link| !link.is_ended())
    }

    /// Whether a Chromium Host relay link is connected.
    pub(crate) fn linked(&self) -> bool {
        self.current_link().is_some()
    }

    fn write_app(&self, frame: &Frame) {
        let _ = write_frame(&mut *self.app.lock().unwrap_or_else(PoisonError::into_inner), frame);
    }

    /// A new relay of `target_id` with a link up: its route (waiting for the
    /// app) and the id its connection starts at.
    pub(super) fn open(&self, target_id: &str) -> (Arc<DirectRoute>, u64) {
        let route = DirectRoute::new(target_id, self.app.clone());
        let previous = self
            .routes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(target_id.to_owned(), route.clone());
        if let Some(previous) = previous {
            previous.close("the relay was reopened");
        }
        let first = self
            .cursors
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(target_id)
            .copied()
            .unwrap_or(DIRECT_FIRST_RAW_ID);
        (route, first)
    }

    /// The relay of `target_id` ended (`conn`, its connection): its route
    /// goes, the link stops relaying it, and its next relay continues the ids.
    pub(super) fn closed(&self, target_id: &str, conn: &CdpConnection, reason: &str) {
        let route = self.routes.lock().unwrap_or_else(PoisonError::into_inner).remove(target_id);
        let Some(route) = route else { return };
        route.close(reason);
        let next = conn.next_id();
        let next = if next >= DIRECT_LAST_RAW_ID - PREPARE_QUEUE_LIMIT as u64 {
            DIRECT_FIRST_RAW_ID
        } else {
            next
        };
        self.cursors
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(target_id.to_owned(), next);
    }

    /// Ends a relay from a reader: its connection closes (its calls fail
    /// with `reason`), its driver goes, and the app hears `cdp.detach`, so
    /// the next call prepares the tab again.
    fn end(&self, target_id: &str, reason: &str) {
        let conn = self.relays.lock().unwrap_or_else(PoisonError::into_inner).remove(target_id);
        self.cef_tabs.lock().unwrap_or_else(PoisonError::into_inner).remove(target_id);
        if let Some(conn) = conn {
            self.closed(target_id, &conn, reason);
            conn.close(reason);
        }
        self.write_app(&Frame::CdpDetach { target_id: target_id.to_owned() });
    }

    fn route(&self, target_id: &str) -> Option<Arc<DirectRoute>> {
        self.routes.lock().unwrap_or_else(PoisonError::into_inner).get(target_id).cloned()
    }

    /// The app's answer to `cdp.prepare` (provider reader thread); true for
    /// an event of this module, which no session sees.
    pub(super) fn app_event(&self, name: &str, payload: &Value) -> bool {
        let target = payload.get("targetId").and_then(Value::as_str);
        match (name, target) {
            ("tab.relay.direct", Some(target_id)) => {
                // The app's JSON numbers are doubles: an integral 7.0 is browser 7.
                let browser = payload
                    .get("browser")
                    .and_then(|browser| {
                        browser.as_i64().or_else(|| {
                            browser.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64)
                        })
                    })
                    .and_then(|browser| i32::try_from(browser).ok());
                let link = payload.get("link").and_then(Value::as_str);
                self.prepared(target_id, browser, link);
                true
            }
            ("tab.relay.failed", Some(target_id)) => {
                let reason = payload
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("the tab's page could not start");
                if self.route(target_id).is_some() {
                    self.end(target_id, reason);
                }
                true
            }
            _ => false,
        }
    }

    /// The tab's page is agent-ready as `browser` of the Chromium Host the
    /// app gave `link`: the relay goes over the link when it is that host's,
    /// else through the app.
    fn prepared(&self, target_id: &str, browser: Option<i32>, link: Option<&str>) {
        let Some(route) = self.route(target_id) else { return };
        let mut state = route.state();
        let Route::Preparing(queued) = &mut *state else { return };
        let queued = std::mem::take(queued);
        let link = self.current_link().filter(|current| current.serves(link));
        if let (Some(link), Some(browser)) = (link, browser) {
            let attached = link
                .write(&Frame::RelayAttach { target_id: target_id.to_owned(), browser })
                .and_then(|()| queued.iter().try_for_each(|message| route.to_host(&link, message)));
            if attached.is_ok() {
                *state = Route::Host(link);
                return;
            }
        }
        // Through the app: it ends its prepared session and relays the tab
        // itself, holding the waiting commands until the page is ready.
        *state = Route::App;
        self.write_app(&Frame::CdpDetach { target_id: target_id.to_owned() });
        self.write_app(&Frame::CdpAttach { target_id: target_id.to_owned() });
        for message in &queued {
            self.write_app(&route.cdp(message));
        }
    }

    /// The Chromium Host's relay link connected (after `relay.hello.ack`): it
    /// replaces any earlier link, and its frames are read on a thread of its
    /// own. `shutdown` ends the socket (the provider left).
    pub(super) fn attach_link(
        self: &Arc<Self>,
        mut reader: impl Read + Send + 'static,
        writer: impl Write + Send + 'static,
        id: String,
        shutdown: Box<dyn Fn() + Send + Sync>,
    ) -> std::io::Result<()> {
        let link = Arc::new(RelayLink {
            writer: Arc::new(Mutex::new(Box::new(writer))),
            id,
            shutdown,
            target: Mutex::new(Arc::downgrade(self)),
            ended: std::sync::atomic::AtomicBool::new(false),
        });
        link.write(&Frame::RelayHelloAck {})?;
        let previous =
            self.link.lock().unwrap_or_else(PoisonError::into_inner).replace(link.clone());
        if let Some(previous) = previous {
            self.end_link(&previous, "the relay link was replaced");
        }
        let reading = link.clone();
        // supervise-allow: this relay link's reader, ending with the link; its end closes the link's relays.
        let spawned = cmux_threads::spawn(
            "cmux-browser-host-relay-link",
            cmux_threads::ThreadQos::UserInitiated,
            move || {
                let link = reading;
                let reason = loop {
                    let frame = read_frame(&mut reader);
                    // A replaced link, or one whose provider ended: its relays
                    // ended then, and nothing takes its frames.
                    let direct = link.target();
                    match frame {
                        Ok(Some(Frame::Cdp { target_id, message })) => {
                            if let Some(direct) = direct {
                                direct.host_message(&link, &target_id, &message);
                            }
                        }
                        Ok(Some(Frame::RelayClosed { target_id, .. })) => {
                            if let Some(direct) = direct
                                && direct
                                    .route(&target_id)
                                    .is_some_and(|route| route.on_link(&link))
                            {
                                direct.end(&target_id, "the tab's page closed");
                            }
                        }
                        Ok(Some(_)) => {}
                        Ok(None) => break "the Chromium Host's relay link closed".to_owned(),
                        Err(error) => {
                            break format!("the Chromium Host's relay link failed: {error}");
                        }
                    }
                };
                link.ended.store(true, Ordering::Release);
                if let Some(direct) = link.target() {
                    direct.link_closed(&link, &reason);
                }
                (link.shutdown)();
            },
        );
        if let Err(error) = spawned {
            link.ended.store(true, Ordering::Release);
            self.link_closed(&link, "the relay link's reader could not start");
            (link.shutdown)();
            return Err(error);
        }
        Ok(())
    }

    /// Ends `link`: its relays end (the app hears `cdp.detach` for each, so
    /// the next call prepares the tab again), its reader hands nothing on,
    /// and its socket closes.
    fn end_link(&self, link: &Arc<RelayLink>, reason: &str) {
        self.link_closed(link, reason);
        link.retarget(Weak::new());
        (link.shutdown)();
    }

    fn host_message(&self, link: &Arc<RelayLink>, target_id: &str, message: &str) {
        let Some(route) = self.route(target_id).filter(|route| route.on_link(link)) else {
            return;
        };
        route.inbound(message);
        let relay =
            self.relays.lock().unwrap_or_else(PoisonError::into_inner).get(target_id).cloned();
        if let Some(relay) = relay {
            relay.receive(message);
        }
    }

    /// `link` ended: each of its relays ends, and the next call attaches
    /// again (through the app while no link is up).
    fn link_closed(&self, link: &Arc<RelayLink>, reason: &str) {
        {
            let mut current = self.link.lock().unwrap_or_else(PoisonError::into_inner);
            if current.as_ref().is_some_and(|current| Arc::ptr_eq(current, link)) {
                *current = None;
            }
        }
        let on_link: Vec<String> = self
            .routes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter(|(_, route)| route.on_link(link))
            .map(|(target_id, _)| target_id.clone())
            .collect();
        for target_id in on_link {
            self.end(&target_id, reason);
        }
    }

    /// The app's provider connection ended: its relays closed with it, and so
    /// does the link. A Chromium Host that outlives the app dials again for
    /// the next app, with the link id that app gives it.
    pub(super) fn provider_closed(&self, reason: &str) {
        for (_, route) in self.routes.lock().unwrap_or_else(PoisonError::into_inner).drain() {
            route.close(reason);
        }
        let link = self.link.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(link) = link {
            link.retarget(Weak::new());
            (link.shutdown)();
        }
    }
}

#[cfg(test)]
#[path = "direct_relay_tests.rs"]
mod tests;
