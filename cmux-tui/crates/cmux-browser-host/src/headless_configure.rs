//! `session.configure` on the shared headless browser (item 4d,
//! driver-protocol.md `session.configure`): the options apply to the tabs
//! the session created (popups too) while it is attached, whichever session
//! drives them; a person's tab keeps its own. Keeping a tab or the
//! session's end undoes them.
//!
//! - `userAgent`, `extraHTTPHeaders`: per tab, from the first request (the
//!   driver sets them before the first navigation; a popup starts with its
//!   opener's).
//! - `proxy`: a private browser context (its own cookie jar) for the tabs
//!   the session opens afterwards; their popups stay in it. Closed at the
//!   session's end unless a tab in it was kept (then at host exit).
//!   Credentials are not supported yet (they need `Fetch.authRequired`).
//! - `permissions`: not supported yet (CDP grants per browser context or
//!   origin, not per tab; owner decision pending).

use crate::cdp::TabOverrides;
use crate::headless_source::HeadlessSource;
use crate::protocol::{DriverError, ErrorCode};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::PoisonError;

#[derive(Debug, Default)]
pub struct SessionConfig {
    overrides: TabOverrides,
    /// The proxy store for tabs opened from now on.
    proxy: Option<String>,
    /// Every proxy store the session made, and whether a kept tab is in it.
    contexts: Vec<(String, bool)>,
    /// Tabs the session opened in a proxy store.
    tab_contexts: HashMap<String, String>,
}

impl SessionConfig {
    fn overrides(&self) -> Option<TabOverrides> {
        (self.overrides != TabOverrides::default()).then(|| self.overrides.clone())
    }
}

fn unsupported(message: &str) -> DriverError {
    DriverError::new(ErrorCode::Unsupported, format!("session.configure: {message}"))
}

impl HeadlessSource {
    fn configs(
        &self,
    ) -> std::sync::MutexGuard<'_, HashMap<u64, SessionConfig>> {
        self.configs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// `session.configure`: each key given replaces its value (`null` clears).
    pub(crate) fn configure(&self, session: u64, params: &Value) -> Result<Value, DriverError> {
        if params.get("permissions").is_some_and(|p| p.as_array().is_some_and(|l| !l.is_empty())) {
            return Err(unsupported("permissions are not supported on the shared headless browser yet"));
        }
        let proxy = match params.get("proxy") {
            None => None,
            Some(Value::Null) => Some(None),
            Some(proxy) => {
                if proxy.get("username").is_some() || proxy.get("password").is_some() {
                    return Err(unsupported("proxy credentials are not supported on headless yet"));
                }
                let server = proxy["server"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| DriverError::invalid("session.configure: proxy: expected { server }"))?;
                Some(Some(self.driver.create_proxy_context(server, proxy["bypass"].as_str())?))
            }
        };
        let (overrides, tabs, answer) = {
            let mut configs = self.configs();
            let config = configs.entry(session).or_default();
            if let Some(ua) = params.get("userAgent") {
                config.overrides.user_agent = ua.as_str().map(str::to_owned);
            }
            if let Some(headers) = params.get("extraHTTPHeaders") {
                config.overrides.headers = headers.as_object().cloned();
            }
            if let Some(proxy) = proxy {
                if let Some(context) = &proxy {
                    config.contexts.push((context.clone(), false));
                }
                config.proxy = proxy;
            }
            let answer = json!({"proxy": config.proxy.is_some()});
            let touched = params.get("userAgent").is_some() || params.get("extraHTTPHeaders").is_some();
            (config.overrides(), touched.then(|| self.routes_tabs_of(session)), answer)
        };
        for target in tabs.into_iter().flatten() {
            let _ = self.driver.set_tab_overrides(&target, overrides.clone());
        }
        Ok(answer)
    }

    /// `tabs.open` with the session's options.
    pub(crate) fn open_configured(&self, session: u64, params: &Value) -> Result<Value, DriverError> {
        let (context, overrides) = {
            let configs = self.configs();
            let config = configs.get(&session);
            (config.and_then(|c| c.proxy.clone()), config.and_then(SessionConfig::overrides))
        };
        let opened = self.driver.open_tab(params, context.as_deref(), overrides)?;
        if let (Some(context), Some(target)) = (context, opened.get("targetId").and_then(Value::as_str)) {
            if let Some(config) = self.configs().get_mut(&session) {
                config.tab_contexts.insert(target.to_owned(), context);
            }
        }
        Ok(opened)
    }

    /// A kept tab is the person's: the session's options leave it, and its
    /// proxy store stays until the host exits.
    pub(crate) fn configure_kept(&self, session: u64, target: &str) {
        let had = {
            let mut configs = self.configs();
            let Some(config) = configs.get_mut(&session) else { return };
            if let Some(context) = config.tab_contexts.remove(target) {
                for entry in config.contexts.iter_mut().filter(|(c, _)| *c == context) {
                    entry.1 = true;
                }
            }
            config.overrides().is_some()
        };
        if had {
            let _ = self.driver.set_tab_overrides(target, None);
        }
    }

    /// The session ended: its options leave its tabs, its proxy stores
    /// without a kept tab close.
    pub(crate) fn configure_ended(&self, session: u64) {
        let Some(config) = self.configs().remove(&session) else { return };
        if config.overrides().is_some() {
            for target in self.routes_tabs_of(session) {
                let _ = self.driver.set_tab_overrides(&target, None);
            }
        }
        for (context, kept) in config.contexts {
            if !kept {
                let _ = self.driver.dispose_context(&context);
            }
        }
    }
}
