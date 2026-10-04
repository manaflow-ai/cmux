//! Engines the host opens on demand.
//!
//! Headless Chromium: one browser process and throwaway profile per session
//! (CDP allows one event handler per connection, and per-session profiles
//! keep sessions' cookies apart). In-app CEF and WebKit tabs arrive through
//! the app's provider connection (step c); until a provider is connected
//! those engines answer `engine_unavailable`.

use crate::cdp::CdpDriver;
use crate::driver::{Driver, EventSink};
use crate::protocol::{DriverError, ErrorCode};
use serde_json::Value;
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

pub struct HostEngines {
    agent_source: Arc<str>,
    #[cfg(unix)]
    provider: ProviderSlot,
}

impl HostEngines {
    pub fn new(agent_source: impl Into<Arc<str>>) -> HostEngines {
        HostEngines {
            agent_source: agent_source.into(),
            #[cfg(unix)]
            provider: Arc::default(),
        }
    }

    /// Where the provider listener puts the app's connection.
    #[cfg(unix)]
    pub fn provider_slot(&self) -> ProviderSlot {
        self.provider.clone()
    }

    #[cfg(unix)]
    fn provider(&self, engine: &str, events: EventSink) -> Result<Arc<dyn Driver>, DriverError> {
        let provider = self
            .provider
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
            .filter(|provider| provider.closed_reason().is_none())
            .ok_or_else(|| {
                unavailable(engine, "the cmux app is not connected to the browser host")
            })?;
        let engine = crate::provider_engine::ProviderEngine::new(
            provider,
            engine,
            self.agent_source.clone(),
            events,
        )?;
        Ok(Arc::new(engine))
    }

    #[cfg(not(unix))]
    fn provider(&self, engine: &str, _events: EventSink) -> Result<Arc<dyn Driver>, DriverError> {
        Err(unavailable(engine, "the cmux app is not connected to the browser host"))
    }
}

fn unavailable(engine: &str, reason: &str) -> DriverError {
    DriverError::new(ErrorCode::Closed, format!("engine_unavailable: {engine}: {reason}"))
}

#[cfg(unix)]
struct HeadlessDriver {
    driver: CdpDriver,
    _browser: crate::cdp::pipe::HeadlessChromium,
}

#[cfg(unix)]
impl Driver for HeadlessDriver {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        self.driver.call(method, params)
    }

    fn capabilities(&self) -> Vec<&'static str> {
        self.driver.capabilities()
    }
}

impl crate::host::Engines for HostEngines {
    fn driver(&self, engine: &str, events: EventSink) -> Result<Arc<dyn Driver>, DriverError> {
        match engine {
            "auto" | "headless" => self.headless(events),
            "cef" | "webkit" => self.provider(engine, events),
            other => Err(DriverError::invalid(format!(
                "engine: expected auto, headless, cef or webkit, got {other:?}"
            ))),
        }
    }
}

impl HostEngines {
    #[cfg(unix)]
    fn headless(&self, events: EventSink) -> Result<Arc<dyn Driver>, DriverError> {
        use crate::cdp::pipe::HeadlessChromium;
        let Some(binary) = chromium_candidates().into_iter().find(|p| p.is_file()) else {
            return Err(unavailable(
                "headless",
                "no Chromium found (set CMUX_BROWSER_HOST_CHROMIUM)",
            ));
        };
        let browser = HeadlessChromium::launch(&headless_options(binary))
            .map_err(|e| unavailable("headless", &e.to_string()))?;
        let driver = CdpDriver::attach_browser(
            browser.connection().clone(),
            self.agent_source.clone(),
            events,
        )?;
        Ok(Arc::new(HeadlessDriver { driver, _browser: browser }))
    }

    #[cfg(not(unix))]
    fn headless(&self, _events: EventSink) -> Result<Arc<dyn Driver>, DriverError> {
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
