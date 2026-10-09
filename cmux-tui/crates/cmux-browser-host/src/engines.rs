//! Engines the host opens on demand.
//!
//! Headless Chromium: one browser process per (host, profile), shared by
//! every headless session of that profile (headless_source.rs, item 4b).
//! In-app CEF and WebKit tabs arrive through
//! the app's provider connection (step c); until a provider is connected
//! those engines answer `engine_unavailable`.

use crate::driver::{Driver, EventSink};
use crate::protocol::{DriverError, ErrorCode};
use std::path::PathBuf;
use std::sync::Arc;

/// Where the host looks for Chromium, in order.
pub fn chromium_candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(path) = std::env::var_os("CMUX_BROWSER_HOST_CHROMIUM").filter(|p| !p.is_empty()) {
        out.push(PathBuf::from(path));
    }
    if let Some(home) = std::env::var_os("HOME") {
        // The optional Chrome for Testing bundle (`cmux browser install-chromium`).
        let base = PathBuf::from(home).join(".cache/cmux/chromium");
        out.push(base.join("chrome-linux64/chrome"));
        out.push(base.join("chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"));
    }
    for path in [
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ] {
        out.push(PathBuf::from(path));
    }
    out
}

/// The app's provider connection, set by the provider listener.
#[cfg(unix)]
pub type ProviderSlot = Arc<std::sync::Mutex<Option<Arc<crate::provider_link::ProviderDriver>>>>;

/// How long a webkit or cef session waits for the app to connect as the
/// provider (a host the daemon just started on an agent connect, before the
/// app's link is up).
pub const PROVIDER_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

pub struct HostEngines {
    agent_source: Arc<str>,
    #[cfg(unix)]
    provider: ProviderSlot,
    /// Notified after the provider connected or left (with the slot's lock).
    #[cfg(unix)]
    provider_changed: Arc<std::sync::Condvar>,
    #[cfg(unix)]
    provider_wait: std::time::Duration,
    /// The shared headless browsers, by profile.
    #[cfg(unix)]
    headless: crate::headless_source::HeadlessBrowsers,
    /// Isolated (a Cloud machine): every headless browser sends all its
    /// traffic through the host's egress listener (crate::egress_scope).
    egress: crate::egress_scope::EgressScope,
}

impl HostEngines {
    pub fn new(agent_source: impl Into<Arc<str>>) -> HostEngines {
        HostEngines {
            agent_source: agent_source.into(),
            #[cfg(unix)]
            provider: Arc::default(),
            #[cfg(unix)]
            provider_changed: Arc::default(),
            #[cfg(unix)]
            provider_wait: PROVIDER_WAIT,
            #[cfg(unix)]
            headless: Arc::default(),
            egress: crate::egress_scope::EgressScope::Machine,
        }
    }

    /// The egress scope of the host (the same one `Host::with_egress` got).
    pub fn with_egress(mut self, egress: crate::egress_scope::EgressScope) -> HostEngines {
        self.egress = egress;
        self
    }

    /// The wait for a provider (default [`PROVIDER_WAIT`]).
    #[cfg(unix)]
    pub fn with_provider_wait(mut self, wait: std::time::Duration) -> HostEngines {
        self.provider_wait = wait;
        self
    }

    /// Where the provider listener puts the app's connection.
    #[cfg(unix)]
    pub fn provider_slot(&self) -> ProviderSlot {
        self.provider.clone()
    }

    /// Wakes sessions that wait for a provider; call after the slot changed.
    #[cfg(unix)]
    pub fn provider_changed(&self) {
        // Taking the lock orders this after the change a waiter checks.
        drop(self.provider.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        self.provider_changed.notify_all();
    }

    #[cfg(unix)]
    fn provider(
        &self,
        engine: &str,
        events: EventSink,
        session: &crate::host::SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        // Signal-driven bounded wait: the app may connect right after an
        // agent connect started this host.
        let deadline = std::time::Instant::now() + self.provider_wait;
        let mut slot = self.provider.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let provider = loop {
            if let Some(provider) =
                slot.clone().filter(|provider| provider.closed_reason().is_none())
            {
                break provider;
            }
            let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) else {
                return Err(unavailable(
                    engine,
                    "the cmux app is not connected to the browser host",
                ));
            };
            slot = self
                .provider_changed
                .wait_timeout(slot, left)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        };
        drop(slot);
        let lease = crate::lease::LeaseCaller {
            session: session.name.clone(),
            actor: session.caller.actor.clone(),
            on_behalf_of: session.caller.on_behalf_of.clone(),
            origin: session.caller.origin.clone(),
            label: session.label.clone(),
            // Host::open refused an unnamed cef/webkit session already.
            implicit_session: false,
            engine: engine.to_owned(),
        };
        // The session's automation.input events also reach the app (`input` frames).
        let events = crate::provider_link::tee_inputs(events, &provider, &session.name);
        let engine = crate::provider_engine::ProviderEngine::new(
            provider,
            engine,
            self.agent_source.clone(),
            events,
            lease,
        )?;
        Ok(Arc::new(engine))
    }

    #[cfg(not(unix))]
    fn provider(
        &self,
        engine: &str,
        _events: EventSink,
        _session: &crate::host::SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        Err(unavailable(engine, "the cmux app is not connected to the browser host"))
    }
}

fn unavailable(engine: &str, reason: &str) -> DriverError {
    DriverError::new(ErrorCode::Closed, format!("engine_unavailable: {engine}: {reason}"))
}

impl crate::host::Engines for HostEngines {
    fn driver(
        &self,
        engine: &str,
        events: EventSink,
        session: &crate::host::SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        match engine {
            "auto" | "headless" => self.headless(events, session),
            "cef" | "webkit" => self.provider(engine, events, session),
            other => Err(DriverError::invalid(format!(
                "engine: expected auto, headless, cef or webkit, got {other:?}"
            ))),
        }
    }
}

impl HostEngines {
    #[cfg(unix)]
    fn headless(
        &self,
        events: EventSink,
        session: &crate::host::SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        use crate::headless_source::{HeadlessSession, HeadlessSource, browser_for};
        let source = browser_for(&self.headless, &session.profile, || {
            let Some(binary) = chromium_candidates().into_iter().find(|p| p.is_file()) else {
                return Err(unavailable(
                    "headless",
                    "no Chromium found (set CMUX_BROWSER_HOST_CHROMIUM)",
                ));
            };
            let mut options = headless_options(binary);
            if let Some(isolated) = self.egress.isolated() {
                // No listener, no browser: an isolated host never launches
                // a Chromium that could reach a refused range.
                options
                    .extra_args
                    .extend(isolated.chromium_args().map_err(|e| unavailable("headless", &e))?);
            }
            HeadlessSource::launch(&options, self.agent_source.clone(), &session.profile)
        })?;
        let lease = crate::lease::LeaseCaller {
            session: session.name.clone(),
            actor: session.caller.actor.clone(),
            on_behalf_of: session.caller.on_behalf_of.clone(),
            origin: session.caller.origin.clone(),
            label: session.label.clone(),
            implicit_session: false,
            engine: "headless".to_owned(),
        };
        let driver =
            HeadlessSession::new(source, &self.headless, self.agent_source.clone(), events, lease)?;
        Ok(Arc::new(driver))
    }

    #[cfg(not(unix))]
    fn headless(
        &self,
        _events: EventSink,
        _session: &crate::host::SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        Err(unavailable("headless", "headless Chromium over a pipe needs a Unix host"))
    }
}

/// Launch options from the environment: `CMUX_BROWSER_HOST_HEADLESS=0` runs
/// headful (Cloud user tabs), `CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE=0`
/// lets Chromium throttle background tabs.
#[cfg(unix)]
fn headless_options(binary: PathBuf) -> crate::cdp::pipe::HeadlessOptions {
    let off = |name: &str| std::env::var(name).is_ok_and(|value| value == "0");
    let mut options = crate::cdp::pipe::HeadlessOptions::new(binary);
    options.headless = !off("CMUX_BROWSER_HOST_HEADLESS");
    options.full_rate_background = !off("CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE");
    options
}

#[cfg(test)]
#[cfg(unix)]
mod provider_wait_tests {
    use super::*;
    use crate::host::{Caller, Host};
    use serde_json::json;
    use std::time::{Duration, Instant};

    fn caller() -> Caller {
        Caller {
            actor: "uid:501".into(),
            on_behalf_of: None,
            origin: "cli".into(),
            locality: Default::default(),
        }
    }

    /// A host the daemon just started on an agent connect: a webkit session
    /// opened before the app's provider link is up waits for it (bounded),
    /// instead of failing at once with engine_unavailable.
    #[test]
    fn a_webkit_session_waits_for_the_app_to_connect() {
        let engines = Arc::new(HostEngines::new(crate::host::agent_bundle()));
        let host = Host::new(engines.clone(), "/tmp");
        let opened = std::thread::spawn(move || {
            host.dispatch(
                &caller(),
                "browser.repl.open",
                &json!({"session": "w", "engine": "webkit"}),
            )
        });
        std::thread::sleep(Duration::from_millis(200));
        let (app, host_end) = std::os::unix::net::UnixStream::pair().unwrap();
        let driver = crate::provider_link::ProviderDriver::start(
            host_end.try_clone().unwrap(),
            host_end,
            crate::driver::discard_events(),
            Vec::new(),
        )
        .unwrap();
        *engines.provider_slot().lock().unwrap() = Some(driver);
        engines.provider_changed();
        let result = opened.join().unwrap();
        assert!(result.is_ok(), "the session opened once the app connected: {result:?}");
        drop(app);
    }

    #[test]
    fn without_an_app_the_session_fails_after_the_wait() {
        let wait = Duration::from_millis(150);
        let engines =
            Arc::new(HostEngines::new(crate::host::agent_bundle()).with_provider_wait(wait));
        let host = Host::new(engines, "/tmp");
        let started = Instant::now();
        let error = host
            .dispatch(&caller(), "browser.repl.open", &json!({"session": "w", "engine": "webkit"}))
            .unwrap_err();
        assert!(started.elapsed() >= wait, "it waited");
        assert!(error.message.contains("engine_unavailable"), "{error:?}");
    }
}
