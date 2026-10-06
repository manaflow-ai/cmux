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
//!   the session opens afterwards; their popups stay in it. Its tabs list
//!   the dataStore `<profile>/proxy-<n>`, and the session's `cookies.*`
//!   without a `targetId` use it. Closed at the session's end unless a tab
//!   in it (a popup too) was kept, then at host exit. Known gap: proxy
//!   credentials answer `unsupported` (they need `Fetch.authRequired`).
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
}

/// A proxy store (a browser context): the session that made it, its
/// `tabs.list` dataStore name, and whether a tab in it was kept (then it
/// stays open until the host exits; otherwise it closes with the session).
#[derive(Debug)]
struct ProxyStore {
    owner: u64,
    name: String,
    kept: bool,
}

/// The sessions' options and the proxy stores of one shared browser.
#[derive(Debug, Default)]
pub struct Configs {
    sessions: HashMap<u64, SessionConfig>,
    stores: HashMap<String, ProxyStore>,
    next_store: u64,
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
    fn configs(&self) -> std::sync::MutexGuard<'_, Configs> {
        self.configs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The `tabs.list` dataStore of a tab in a proxy store (None: the
    /// profile's).
    pub(crate) fn data_store_of(&self, target: &str) -> Option<String> {
        let context = self.driver.tab_context(target)?;
        self.configs().stores.get(&context).map(|store| store.name.clone())
    }

    /// The session's proxy store, for its tab-less `cookies.*`.
    pub(crate) fn proxy_of(&self, session: u64) -> Option<String> {
        self.configs().sessions.get(&session).and_then(|c| c.proxy.clone())
    }

    /// `session.configure`: each key given replaces its value (`null` clears).
    pub(crate) fn configure(&self, session: u64, params: &Value) -> Result<Value, DriverError> {
        if params.get("permissions").is_some_and(|p| p.as_array().is_some_and(|l| !l.is_empty())) {
            return Err(unsupported(
                "permissions are not supported on the shared headless browser yet",
            ));
        }
        let proxy = match params.get("proxy") {
            None => None,
            Some(Value::Null) => Some(None),
            Some(proxy) => {
                if proxy.get("username").is_some() || proxy.get("password").is_some() {
                    return Err(unsupported("proxy credentials are not supported on headless yet"));
                }
                let server =
                    proxy["server"].as_str().filter(|s| !s.is_empty()).ok_or_else(|| {
                        DriverError::invalid("session.configure: proxy: expected { server }")
                    })?;
                Some(Some(self.driver.create_proxy_context(server, proxy["bypass"].as_str())?))
            }
        };
        let (overrides, tabs, answer) = {
            let mut configs = self.configs();
            if let Some(Some(context)) = &proxy {
                configs.next_store += 1;
                let name = format!("{}/proxy-{}", self.profile, configs.next_store);
                configs
                    .stores
                    .insert(context.clone(), ProxyStore { owner: session, name, kept: false });
            }
            let config = configs.sessions.entry(session).or_default();
            if let Some(ua) = params.get("userAgent") {
                config.overrides.user_agent = ua.as_str().map(str::to_owned);
            }
            if let Some(headers) = params.get("extraHTTPHeaders") {
                config.overrides.headers = headers.as_object().cloned();
            }
            if let Some(proxy) = proxy {
                config.proxy = proxy;
            }
            let answer = json!({"proxy": config.proxy.is_some()});
            let touched =
                params.get("userAgent").is_some() || params.get("extraHTTPHeaders").is_some();
            (config.overrides(), touched.then(|| self.routes_tabs_of(session)), answer)
        };
        for target in tabs.into_iter().flatten() {
            let _ = self.driver.set_tab_overrides(&target, overrides.clone());
        }
        Ok(answer)
    }

    /// `tabs.open` with the session's options.
    pub(crate) fn open_configured(
        &self,
        session: u64,
        params: &Value,
    ) -> Result<Value, DriverError> {
        let (context, overrides) = {
            let configs = self.configs();
            let config = configs.sessions.get(&session);
            (config.and_then(|c| c.proxy.clone()), config.and_then(SessionConfig::overrides))
        };
        self.driver.open_tab(params, context.as_deref(), overrides)
    }

    /// A kept tab is the person's: the creating session's options leave it,
    /// and the proxy store it is in (any tab, a popup too) stays open until
    /// the host exits.
    pub(crate) fn configure_kept(&self, session: u64, target: &str, created: bool) {
        let context = self.driver.tab_context(target);
        let had = {
            let mut configs = self.configs();
            if let Some(store) = context.and_then(|c| configs.stores.get_mut(&c)) {
                store.kept = true;
            }
            created && configs.sessions.get(&session).is_some_and(|c| c.overrides().is_some())
        };
        if had {
            let _ = self.driver.set_tab_overrides(target, None);
        }
    }

    /// The session ended: its options leave its tabs, its proxy stores
    /// without a kept tab close.
    pub(crate) fn configure_ended(&self, session: u64) {
        let (config, closing) = {
            let mut configs = self.configs();
            let config = configs.sessions.remove(&session);
            let closing: Vec<String> = configs
                .stores
                .iter()
                .filter(|(_, store)| store.owner == session && !store.kept)
                .map(|(context, _)| context.clone())
                .collect();
            for context in &closing {
                configs.stores.remove(context);
            }
            (config, closing)
        };
        if config.is_some_and(|c| c.overrides().is_some()) {
            for target in self.routes_tabs_of(session) {
                let _ = self.driver.set_tab_overrides(&target, None);
            }
        }
        for context in closing {
            let _ = self.driver.dispose_context(&context);
        }
    }
}
