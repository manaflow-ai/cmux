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
//! - `permissions` (chief, 2026-10-06, option 2): CDP grants per browser
//!   context, never per tab, so the session's new tabs open in a private
//!   store (`<profile>/private-<n>`, or its proxy store) that has the
//!   grants; no grant reaches a person's tab. A private store starts with a
//!   one-way copy of the profile's cookies (never written back) and closes
//!   like a proxy store. Clipboard grants are refused: page script never
//!   gets the browser's clipboard. `null` or `[]` drops the grants; new tabs
//!   then open in the profile again (a proxy store keeps them).
//! - `incognito` (private data P1): every tab the session opens goes to its
//!   incognito store, as does `tabs.open {incognito: true}` from any
//!   session: an in-memory browser context with no cookie of the profile
//!   (nothing is copied in or written back), named `<profile>/incognito-<n>`
//!   and listed `incognito: true`. Its tabs (popups too) cannot be kept;
//!   the store closes when the session ends. In an incognito session a
//!   `tabs.open {incognito: false}` is refused, the session's tab-less
//!   `cookies.*` use the incognito store, and a tab-less `net.fetch` is
//!   refused (its hidden shell runs in the profile's store). Turning it
//!   off again is refused (one way, like a policy lock). Known gap:
//!   incognito with a proxy or permission grants answers `unsupported`.

use crate::cdp::TabOverrides;
use crate::headless_source::HeadlessSource;
use crate::protocol::{DriverError, ErrorCode};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::PoisonError;

#[derive(Debug, Default)]
pub struct SessionConfig {
    overrides: TabOverrides,
    /// The store (browser context) for tabs opened from now on: a proxy
    /// store, or a private one for permissions; None: the profile.
    store: Option<String>,
    /// Whether `store` is a proxy store.
    store_proxy: bool,
    /// The granted permissions (CDP names).
    permissions: Vec<String>,
    /// `session.configure {incognito}`: every tab opens incognito.
    incognito: bool,
    /// The session's incognito store, made on first use.
    incognito_store: Option<String>,
}

/// A `session.configure` permission name -> CDP `Browser.PermissionType`.
fn cdp_permission(name: &str) -> Result<&'static str, DriverError> {
    Ok(match name {
        "geolocation" => "geolocation",
        "notifications" => "notifications",
        "camera" => "videoCapture",
        "microphone" => "audioCapture",
        "midi" => "midi",
        "midi-sysex" => "midiSysex",
        "background-sync" => "backgroundSync",
        "ambient-light-sensor" | "accelerometer" | "gyroscope" | "magnetometer" => "sensors",
        "payment-handler" => "paymentHandler",
        "storage-access" => "storageAccess",
        "local-fonts" => "localFonts",
        "idle-detection" => "idleDetection",
        "window-management" => "windowManagement",
        "screen-wake-lock" => "wakeLockScreen",
        "clipboard-read" | "clipboard-write" => {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                "session.configure: clipboard permissions are never granted; the tab's clipboard is clipboard.read/write",
            ));
        }
        other => {
            return Err(DriverError::invalid(format!(
                "session.configure: permissions: unknown permission {other:?}"
            )));
        }
    })
}

/// A proxy store (a browser context): the session that made it, its
/// `tabs.list` dataStore name, and whether a tab in it was kept (then it
/// stays open until the host exits; otherwise it closes with the session).
#[derive(Debug)]
struct ProxyStore {
    owner: u64,
    name: String,
    kept: bool,
    /// An incognito store: its tabs are never kept.
    incognito: bool,
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

    /// Whether a tab is in an incognito store.
    pub(crate) fn is_incognito(&self, target: &str) -> bool {
        let Some(context) = self.driver.tab_context(target) else { return false };
        self.configs().stores.get(&context).is_some_and(|store| store.incognito)
    }

    /// Whether the session is incognito (`session.configure`).
    pub(crate) fn session_incognito(&self, session: u64) -> bool {
        self.configs().sessions.get(&session).is_some_and(|c| c.incognito)
    }

    /// The store of the session's tab-less `cookies.*`: its incognito store
    /// in an incognito session (made now if needed), else its proxy or
    /// private store, else None (the profile's).
    pub(crate) fn cookie_store_of(&self, session: u64) -> Result<Option<String>, DriverError> {
        if self.session_incognito(session) {
            return self.incognito_store(session).map(Some);
        }
        Ok(self.configs().sessions.get(&session).and_then(|c| c.store.clone()))
    }

    /// The session's incognito store, made on first use.
    fn incognito_store(&self, session: u64) -> Result<String, DriverError> {
        {
            let configs = self.configs();
            let config = configs.sessions.get(&session);
            if let Some(store) = config.and_then(|c| c.incognito_store.clone()) {
                return Ok(store);
            }
            if config.is_some_and(|c| c.store.is_some()) {
                return Err(unsupported(
                    "incognito tabs with a proxy or permission grants are not supported yet",
                ));
            }
        }
        let context = self.driver.create_incognito_context()?;
        let mut configs = self.configs();
        configs.next_store += 1;
        let name = format!("{}/incognito-{}", self.profile, configs.next_store);
        configs.stores.insert(
            context.clone(),
            ProxyStore { owner: session, name, kept: false, incognito: true },
        );
        configs.sessions.entry(session).or_default().incognito_store = Some(context.clone());
        Ok(context)
    }

    /// `session.configure`: each key given replaces its value (`null` clears).
    pub(crate) fn configure(&self, session: u64, params: &Value) -> Result<Value, DriverError> {
        let permissions: Option<Vec<String>> = match params.get("permissions") {
            None => None,
            Some(Value::Null) => Some(Vec::new()),
            Some(Value::Array(list)) => Some(
                list.iter()
                    .map(|name| cdp_permission(name.as_str().unwrap_or("")).map(str::to_owned))
                    .collect::<Result<_, _>>()?,
            ),
            Some(_) => {
                return Err(DriverError::invalid(
                    "session.configure: permissions: expected an array of names",
                ));
            }
        };
        let incognito = match params.get("incognito") {
            None => None,
            Some(Value::Null) => Some(false),
            Some(Value::Bool(on)) => Some(*on),
            Some(_) => {
                return Err(DriverError::invalid(
                    "session.configure: incognito: expected a boolean",
                ));
            }
        };
        // Checked before anything changes: incognito stores take no proxy
        // and no grants yet.
        {
            let configs = self.configs();
            let current = configs.sessions.get(&session);
            let incognito_on = incognito.unwrap_or(current.is_some_and(|c| c.incognito));
            let proxy_on = match params.get("proxy") {
                None => current.is_some_and(|c| c.store_proxy),
                Some(Value::Null) => false,
                Some(_) => true,
            };
            let grants_on = match &permissions {
                None => current.is_some_and(|c| !c.permissions.is_empty()),
                Some(list) => !list.is_empty(),
            };
            // One way: an incognito session (the app sets it for an
            // incognito workspace) cannot leave it.
            if current.is_some_and(|c| c.incognito) && incognito == Some(false) {
                return Err(DriverError::new(
                    ErrorCode::Forbidden,
                    "session.configure: an incognito session stays incognito",
                ));
            }
            if incognito_on && (proxy_on || grants_on) {
                return Err(unsupported(
                    "incognito with a proxy or permission grants is not supported yet",
                ));
            }
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
        let (overrides, tabs, stores_changed) = {
            let mut configs = self.configs();
            if let Some(Some(context)) = &proxy {
                configs.next_store += 1;
                let name = format!("{}/proxy-{}", self.profile, configs.next_store);
                configs.stores.insert(
                    context.clone(),
                    ProxyStore { owner: session, name, kept: false, incognito: false },
                );
            }
            let config = configs.sessions.entry(session).or_default();
            if let Some(ua) = params.get("userAgent") {
                config.overrides.user_agent = ua.as_str().map(str::to_owned);
            }
            if let Some(headers) = params.get("extraHTTPHeaders") {
                config.overrides.headers = headers.as_object().cloned();
            }
            let stores_changed = proxy.is_some() || permissions.is_some();
            if let Some(proxy) = proxy {
                config.store_proxy = proxy.is_some();
                config.store = proxy;
            }
            if let Some(permissions) = permissions {
                config.permissions = permissions;
            }
            if let Some(incognito) = incognito {
                config.incognito = incognito;
            }
            // Grants without a proxy store: back to the profile once none
            // is left (the private store closes at the session's end).
            if config.permissions.is_empty() && !config.store_proxy {
                config.store = None;
            }
            let touched =
                params.get("userAgent").is_some() || params.get("extraHTTPHeaders").is_some();
            (config.overrides(), touched.then(|| self.routes_tabs_of(session)), stores_changed)
        };
        for target in tabs.into_iter().flatten() {
            let _ = self.driver.set_tab_overrides(&target, overrides.clone());
        }
        if stores_changed {
            self.grant_session_permissions(session)?;
        }
        let configs = self.configs();
        let config = configs.sessions.get(&session);
        Ok(json!({
            "proxy": config.is_some_and(|c| c.store_proxy),
            "incognito": config.is_some_and(|c| c.incognito),
        }))
    }

    /// Puts the session's grants on its store, making a private store
    /// first when it has grants and no store.
    fn grant_session_permissions(&self, session: u64) -> Result<(), DriverError> {
        let (store, permissions) = {
            let configs = self.configs();
            let config = configs.sessions.get(&session);
            (
                config.and_then(|c| c.store.clone()),
                config.map(|c| c.permissions.clone()).unwrap_or_default(),
            )
        };
        let store = match store {
            Some(store) => store,
            None if permissions.is_empty() => return Ok(()),
            None => {
                let context = self.driver.create_private_context()?;
                let mut configs = self.configs();
                configs.next_store += 1;
                let name = format!("{}/private-{}", self.profile, configs.next_store);
                configs.stores.insert(
                    context.clone(),
                    ProxyStore { owner: session, name, kept: false, incognito: false },
                );
                if let Some(config) = configs.sessions.get_mut(&session) {
                    config.store = Some(context.clone());
                }
                context
            }
        };
        self.driver.set_context_permissions(&store, &permissions)
    }

    /// `tabs.open` with the session's options.
    pub(crate) fn open_configured(
        &self,
        session: u64,
        params: &Value,
    ) -> Result<Value, DriverError> {
        let asked = match params.get("incognito") {
            None | Some(Value::Null) => None,
            Some(Value::Bool(on)) => Some(*on),
            Some(_) => {
                return Err(DriverError::invalid("tabs.open: incognito: expected a boolean"));
            }
        };
        let (context, overrides, incognito_session) = {
            let configs = self.configs();
            let config = configs.sessions.get(&session);
            (
                config.and_then(|c| c.store.clone()),
                config.and_then(SessionConfig::overrides),
                config.is_some_and(|c| c.incognito),
            )
        };
        if incognito_session && asked == Some(false) {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                "tabs.open: this session is incognito; it opens no tab in the profile's store",
            ));
        }
        let mut params = params.clone();
        if let Some(fields) = params.as_object_mut() {
            fields.remove("incognito");
        }
        if asked.unwrap_or(incognito_session) {
            let store = self.incognito_store(session)?;
            return self.driver.open_tab(&params, Some(&store), overrides);
        }
        self.driver.open_tab(&params, context.as_deref(), overrides)
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
