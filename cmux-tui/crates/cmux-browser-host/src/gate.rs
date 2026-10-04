//! The policy gate between a session's VM and its driver.
//!
//! Every `__cmuxNative.driverCall` lands here before any driver sees it:
//! navigation targets are checked against the domain policy, raw CDP needs
//! the session's grant, secret handles are resolved into values only for a
//! focused frame on the secret's domains, and every result that goes back
//! into the VM is masked, so agent code cannot read a user secret back from
//! the page either.

use crate::driver::Driver;
use crate::policy::{Layer, Policy, Writer, parse_patterns};
use crate::protocol::{DriverError, ErrorCode};
use crate::secrets::{TabSecrets, Vault};
use crate::vm::VmHost;
use serde_json::{Value, json};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

mod guards;

/// Per-session grants decided by the session's opener (user or mux).
#[derive(Debug, Clone, Default)]
pub struct Grants {
    /// `browser.cdp`: raw CDP on Chromium tabs.
    pub raw_cdp: bool,
}

pub struct Gate {
    driver: Arc<dyn Driver>,
    policy: Arc<Mutex<Policy>>,
    vault: Mutex<Vault>,
    grants: Grants,
    /// Navigations the policy refused (`session.blockedNavigations()`).
    log: Mutex<Vec<Value>>,
    /// False while a policy is active that the engine cannot enforce on the
    /// page's own requests (no request filter): every call fails closed.
    filter_enforced: std::sync::atomic::AtomicBool,
    /// Secrets typed into tabs by any session of the host.
    tab_secrets: Arc<TabSecrets>,
    /// `automation.input` events for this lease session, if published.
    inputs: Option<crate::automation_input::InputEmitter>,
}

/// Finds the URL of the frame that holds keyboard focus. Same-origin child
/// frames are followed; focus inside a cross-origin frame cannot be read
/// from here and reports `null`, which refuses secret typing.
const FOCUSED_FRAME_URL: &str = "() => { let doc = document; for (let i = 0; i < 16; i++) { \
    const el = doc.activeElement; if (!el || (el.tagName !== 'IFRAME' && el.tagName !== 'FRAME')) return doc.location.href; \
    let inner = null; try { inner = el.contentDocument; } catch (e) { inner = null; } if (!inner) return null; doc = inner; } return null; }";

impl Gate {
    pub fn new(driver: Arc<dyn Driver>, grants: Grants) -> Gate {
        Gate {
            driver,
            policy: Arc::new(Mutex::new(Policy::default())),
            vault: Mutex::new(Vault::default()),
            grants,
            log: Mutex::new(Vec::new()),
            filter_enforced: std::sync::atomic::AtomicBool::new(true),
            tab_secrets: Arc::default(),
            inputs: None,
        }
    }

    /// Publishes `automation.input` for the inputs this session dispatches,
    /// on the session's own event sink, as lease session `session`.
    pub fn with_input_events(mut self, session: &str, sink: crate::driver::EventSink) -> Gate {
        self.inputs = Some(crate::automation_input::InputEmitter::new(session, sink));
        self
    }

    /// Shares the host's record of secrets typed into tabs, so this session
    /// masks what any session typed (and records what it types itself).
    pub fn with_tab_secrets(mut self, tab_secrets: Arc<TabSecrets>) -> Gate {
        self.tab_secrets = tab_secrets;
        self
    }

    /// The session ends: the driver releases its per-session state now.
    pub fn end_session(&self) {
        self.driver.end_session();
    }

    /// Masks a value from (or about) one tab: the session's own secrets and
    /// the secrets any session typed into that tab.
    pub fn mask_for_target(&self, target: Option<&str>, value: &Value) -> Value {
        let value = self.mask_value(value);
        match target.and_then(|target| self.tab_secrets.masker(target)) {
            Some(masker) => masker.mask_value(&value),
            None => value,
        }
    }

    fn mask_text_for_target(&self, target: Option<&str>, text: &str) -> String {
        let text = self.mask(text);
        match target.and_then(|target| self.tab_secrets.masker(target)) {
            Some(masker) => masker.mask(&text).into_owned(),
            None => text,
        }
    }

    /// Masks a driver event for this session; a closed tab's record ends.
    pub fn mask_event(&self, name: &str, payload: &Value) -> Value {
        let target = payload.get("targetId").and_then(Value::as_str);
        let masked = self.mask_for_target(target, payload);
        if matches!(name, "tab.gone" | "tab.closed")
            && let Some(target) = target
        {
            self.tab_secrets.forget(target);
        }
        masked
    }

    /// Owner-side policy change (`browser.policy.set`, user origin or the
    /// session's creator mux).
    pub fn set_owner_policy(&self, layer: Layer, lock: bool) -> Result<(), DriverError> {
        self.policy
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .set(Writer::Owner, layer, lock)
            .map_err(|e| DriverError::new(ErrorCode::Forbidden, e.0))?;
        self.sync_request_filter();
        Ok(())
    }

    /// Hands the engine a request filter while any policy layer is active,
    /// so requests the page makes itself (script navigation, links, popups,
    /// redirects, fetch) are decided before they are sent.
    fn sync_request_filter(&self) {
        let active = {
            let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
            policy.base().is_active() || policy.agent().is_active()
        };
        let filter: Option<crate::driver::RequestFilter> = active.then(|| {
            let policy = self.policy.clone();
            // The session's policy is the same for every tab it drives.
            let filter: crate::driver::RequestFilter = Arc::new(move |_target: &str, url: &str| {
                let parsed = url::Url::parse(url).ok()?;
                policy.lock().unwrap_or_else(PoisonError::into_inner).subresource_refusal(&parsed)
            });
            filter
        });
        let wanted = filter.is_some();
        let installed = self.driver.set_request_filter(filter);
        self.filter_enforced.store(!wanted || installed, std::sync::atomic::Ordering::SeqCst);
    }

    /// Owner-side secrets (`browser.secrets.load`): values never enter the VM.
    pub fn load_secret(
        &self,
        name: &str,
        value: &str,
        domains: &[String],
        totp: bool,
    ) -> Result<(), DriverError> {
        self.vault
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .set(name, value, domains, totp, false)
            .map_err(|e| DriverError::invalid(e.0))
    }

    /// The current masker (for streamed print output).
    pub fn masker(&self) -> crate::secrets::Masker {
        self.vault.lock().unwrap_or_else(PoisonError::into_inner).masker()
    }

    /// Masks text that leaves the host (print output, errors, logs).
    pub fn mask(&self, text: &str) -> String {
        self.vault.lock().unwrap_or_else(PoisonError::into_inner).masker().mask(text).into_owned()
    }

    pub fn mask_value(&self, value: &Value) -> Value {
        self.vault.lock().unwrap_or_else(PoisonError::into_inner).masker().mask_value(value)
    }

    fn refuse(message: impl Into<String>) -> DriverError {
        DriverError::new(ErrorCode::Forbidden, message)
    }

    fn check(&self, method: &str, params: &Value) -> Result<(), DriverError> {
        let (title, url) = match method {
            "tab.navigate" => ("page.goto", params.get("url").and_then(Value::as_str)),
            "tabs.open" => (
                "tabs.open",
                params.get("url").and_then(Value::as_str).filter(|url| !url.is_empty()),
            ),
            "frame.evaluate" if params.get("world").and_then(Value::as_str) == Some("host") => {
                return Err(Self::refuse(
                    "frame.evaluate: the host world is not available to sessions",
                ));
            }
            "cdp" if !self.grants.raw_cdp => {
                return Err(Self::refuse(
                    "cdp: raw CDP needs the browser.cdp grant for this session",
                ));
            }
            "session.configure" if params.get("contentRules").is_some() => {
                return Err(Self::refuse(
                    "session.configure: content rules come from the host's domain policy",
                ));
            }
            _ => ("", None),
        };
        if let Some(url) = url {
            let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(reason) = policy.navigation_refusal(url) {
                let at = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0);
                self.log.lock().unwrap_or_else(PoisonError::into_inner).push(json!({
                    "url": url, "reason": reason, "at": at, "blocked": "before"
                }));
                return Err(Self::refuse(format!("{title}: {url} is blocked: {reason}")));
            }
        }
        Ok(())
    }

    /// Replaces a `{__secret: name}` handle in `params[field]` with its text.
    fn resolve_secret(&self, params: &mut Value, field: &str) -> Result<(), DriverError> {
        let Some(name) = params
            .get(field)
            .and_then(|v| v.get("__secret"))
            .and_then(Value::as_str)
            .map(str::to_owned)
        else {
            return Ok(());
        };
        if self.vault.lock().unwrap_or_else(PoisonError::into_inner).agent_known(&name)
            == Some(false)
        {
            // A user secret could be read back from the page by agent code;
            // it is typed only into a sealed, freshly reloaded tab
            // (browser-host.md decision 8), which is not built yet.
            return Err(Self::refuse(format!(
                "locator.type: secret {name:?} is typed only into a sealed tab, which this host cannot make yet"
            )));
        }
        if self.grants.raw_cdp {
            // Raw CDP can rewrite the agent world that reports focus.
            return Err(Self::refuse(format!(
                "locator.type: secret {name:?} cannot be typed in a session with raw CDP access"
            )));
        }
        let target = params.get("targetId").cloned().unwrap_or(Value::Null);
        let frame_url = self.driver.call(
            "frame.evaluate",
            &json!({"targetId": target, "world": "host", "source": FOCUSED_FRAME_URL, "args": []}),
        )?;
        let Some(frame_url) = frame_url.as_str() else {
            return Err(Self::refuse(format!(
                "secret {name:?}: the focused field is in a frame the host cannot verify"
            )));
        };
        let now =
            SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
        let (text, typed) = {
            let vault = self.vault.lock().unwrap_or_else(PoisonError::into_inner);
            let text =
                vault.text_for_frame(&name, frame_url, now).map_err(|e| Self::refuse(e.0))?;
            (text, vault.typed_value(&name).map(str::to_owned))
        };
        // Every session masks it in this tab from now on, not only this one.
        if let Some(target) = target.as_str() {
            if let Some(value) = typed {
                self.tab_secrets.record(target, &name, &value);
            } else if let Some(key) = self.vault().totp_key(&name) {
                self.tab_secrets.record_totp(target, &name, key);
            }
        }
        params[field] = Value::String(text);
        Ok(())
    }

    /// Main's `input.insertText { secret: name }`: the same check and typing
    /// as a `{__secret}` handle in `text`; a secret with a text is invalid.
    fn secret_insert(params: &mut Value) -> Result<(), DriverError> {
        let Some(secret) = params.as_object_mut().and_then(|p| p.remove("secret")) else {
            return Ok(());
        };
        let Some(name) = secret.as_str() else {
            return Err(DriverError::invalid("input.insertText: secret must be a secret name"));
        };
        if params.get("text").is_some_and(|text| !text.is_null()) {
            return Err(DriverError::invalid(
                "input.insertText: give a secret or a text, not both",
            ));
        }
        params["text"] = json!({"__secret": name});
        Ok(())
    }
}

impl VmHost for Gate {
    fn driver_call(&self, method: &str, params: Value) -> Result<Value, DriverError> {
        if !self.filter_enforced.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                format!(
                    "{method}: this engine cannot apply the domain policy to requests the page makes itself; \
                     clear the policy or use engine \"headless\""
                ),
            ));
        }
        self.check(method, &params)?;
        self.check_cookies(method, &params)?;
        let mut params = params;
        if method == "input.insertText" {
            Self::secret_insert(&mut params)?;
        }
        if matches!(method, "input.insertText" | "input.key") {
            self.resolve_secret(&mut params, "text")?;
        }
        // Every check passed: the app's agent cursor learns of the input
        // right before it is dispatched (a refused input emits nothing).
        if let Some(inputs) = &self.inputs
            && let Some(planned) = inputs.plan(method, &params)
        {
            inputs.publish(planned, &|event| self.driver.send_session_event(event));
        }
        let target = params.get("targetId").and_then(Value::as_str).map(str::to_owned);
        let target = target.as_deref();
        let result = match method {
            "tab.screenshot" | "tab.pdf" => self.capture(method, &params),
            _ => self.driver.call(method, &params).map(|value| self.filter_cookies(method, value)),
        };
        if method == "tabs.close"
            && result.is_ok()
            && let Some(target) = target
        {
            self.tab_secrets.forget(target);
        }
        match result {
            Ok(value) => Ok(self.mask_for_target(target, &value)),
            Err(mut error) => {
                error.message = self.mask_text_for_target(target, &error.message);
                error.error_name =
                    error.error_name.map(|name| self.mask_text_for_target(target, &name));
                error.data = error.data.map(|data| self.mask_for_target(target, &data));
                Err(error)
            }
        }
    }

    /// Main's native ABI (port plan D1): `secrets(op, args)` and
    /// `policy(op, args)`, reached as `native("secrets" | "policy",
    /// {op, args})`. Values never appear in an answer.
    fn native(&self, name: &str, call: Value) -> Result<Value, String> {
        let op = call["op"].as_str().unwrap_or("");
        let args = &call["args"];
        match name {
            "secrets" => self.secrets_op(op, args),
            "policy" => self.policy_op(op, args),
            other => Err(format!("unknown host function {other}")),
        }
    }

    /// The session's secrets and every secret typed into any tab: a file
    /// belongs to no single tab.
    fn mask_bytes(&self, bytes: &[u8]) -> Vec<u8> {
        let mut masker = self.masker();
        masker.merge(&self.tab_secrets.all_masker());
        masker.mask_bytes(bytes)
    }
}

impl Gate {
    fn vault(&self) -> std::sync::MutexGuard<'_, Vault> {
        self.vault.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Agent code may not replace or delete a secret the user gave the host.
    fn refuse_user_secret(&self, title: &str, name: &str) -> Result<(), String> {
        if self.vault().agent_known(name) == Some(false) {
            return Err(format!("{title}: {name} is a user secret; agent code cannot change it"));
        }
        Ok(())
    }

    fn set_secret(
        &self,
        name: &str,
        value: &str,
        domains: &[String],
        totp: bool,
    ) -> Result<Value, String> {
        self.refuse_user_secret("secrets.set", name)?;
        self.vault().set(name, value, domains, totp, true).map_err(|e| e.0)?;
        Ok(described(name, domains, totp))
    }

    fn secrets_op(&self, op: &str, args: &Value) -> Result<Value, String> {
        let text = |key: &str| args[key].as_str().unwrap_or("").to_owned();
        match op {
            "set" => {
                let domains = strings(&args["domains"]);
                self.set_secret(&text("name"), &text("value"), &domains, args["totp"].as_bool().unwrap_or(false))
            }
            // {"<domain pattern>": {name: value | {value, totp}}}; a name with
            // the same value under several patterns gets all of them.
            "load" => {
                let Some(map) = args["object"].as_object() else {
                    return Err("secrets.load: expected { \"<domain pattern>\": { name: value } }".into());
                };
                let mut merged: Vec<(String, String, Vec<String>, bool)> = Vec::new();
                for (pattern, entries) in map {
                    let Some(entries) = entries.as_object() else {
                        return Err(format!("secrets.load: {pattern:?}: a secret needs domains; expected {{ \"<domain pattern>\": {{ name: value }} }}"));
                    };
                    for (name, v) in entries {
                        let value = v.get("value").and_then(Value::as_str).or(v.as_str()).unwrap_or("").to_owned();
                        let totp = v.get("totp").and_then(Value::as_bool).unwrap_or(false);
                        match merged.iter_mut().find(|m| &m.0 == name && m.1 == value) {
                            Some(m) => {
                                m.2.push(pattern.clone());
                                m.3 |= totp;
                            }
                            None => merged.push((name.clone(), value, vec![pattern.clone()], totp)),
                        }
                    }
                }
                let mut out = Vec::new();
                for (name, value, domains, totp) in merged {
                    out.push(self.set_secret(&name, &value, &domains, totp)?);
                }
                Ok(Value::Array(out))
            }
            "list" => Ok(Value::Array(
                self.vault()
                    .list()
                    .into_iter()
                    .map(|s| json!({"name": s.name, "domains": s.domains, "totp": s.totp, "agentKnown": s.agent_known}))
                    .collect(),
            )),
            "has" => Ok(json!(self.vault().agent_known(&text("name")).is_some())),
            "delete" => {
                let name = text("name");
                self.refuse_user_secret("secrets.delete", &name)?;
                Ok(json!(self.vault().delete(&name)))
            }
            "clear" => {
                let mut vault = self.vault();
                let agent: Vec<String> = vault.list().into_iter().filter(|s| s.agent_known).map(|s| s.name).collect();
                for name in agent {
                    vault.delete(&name);
                }
                Ok(Value::Null)
            }
            other => Err(format!("secrets: unknown operation {other:?}")),
        }
    }

    fn policy_op(&self, op: &str, args: &Value) -> Result<Value, String> {
        match op {
            "get" => Ok(effective(&self.policy.lock().unwrap_or_else(PoisonError::into_inner))),
            "check" => {
                let url = args["url"].as_str().unwrap_or("");
                let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
                Ok(policy.navigation_refusal(url).map_or(Value::Null, Value::String))
            }
            "site" => Ok(json!(crate::policy::site_of(args["host"].as_str().unwrap_or("")))),
            // The host's own log of blocked navigations (cmux-next: the host
            // blocks before the request, so the runtime does not see these).
            "log" => {
                Ok(Value::Array(self.log.lock().unwrap_or_else(PoisonError::into_inner).clone()))
            }
            // Agent code may only narrow: the host intersects with the user's
            // layer and refuses changes after a lock.
            "set" => {
                let title = args["title"].as_str().unwrap_or("session.policy");
                let mut policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
                let mut layer = policy.agent().clone();
                let parse = |v: &Value| {
                    parse_patterns(&strings(v)).map_err(|e| format!("{title}: {}", e.0))
                };
                match args.get("allowed") {
                    Some(Value::Null) => layer.allowed = None,
                    Some(list) => {
                        let parsed = parse(list)?;
                        layer.allowed = (!parsed.is_empty()).then_some(parsed);
                    }
                    None => {}
                }
                if let Some(list) = args.get("prohibited") {
                    layer.prohibited = parse(list)?;
                }
                if let Some(block) = args.get("blockIPs").and_then(Value::as_bool) {
                    layer.block_ips = block;
                }
                let lock = args["lock"].as_bool().unwrap_or(false);
                policy.set(Writer::Agent, layer, lock).map_err(|e| format!("{title}: {}", e.0))?;
                let answer = effective(&policy);
                drop(policy);
                self.sync_request_filter();
                Ok(answer)
            }
            other => Err(format!("policy: unknown operation {other:?}")),
        }
    }
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// `{name, domains, totp}`, main's described secret.
fn described(name: &str, domains: &[String], totp: bool) -> Value {
    json!({"name": name, "domains": domains, "totp": totp})
}

/// The effective policy as the runtime shows it: the narrower allow list,
/// the union of prohibited domains, IP blocking from either layer.
fn effective(policy: &Policy) -> Value {
    let raw = |list: &[crate::policy::DomainPattern]| {
        list.iter().map(|p| p.raw.clone()).collect::<Vec<_>>()
    };
    let (base, agent) = (policy.base(), policy.agent());
    let allowed = agent.allowed.as_deref().or(base.allowed.as_deref()).map(raw);
    let mut prohibited = raw(&base.prohibited);
    for p in raw(&agent.prohibited) {
        if !prohibited.contains(&p) {
            prohibited.push(p);
        }
    }
    json!({
        "allowed": allowed,
        "prohibited": prohibited,
        "blockIPs": base.block_ips || agent.block_ips,
        "locked": policy.locked(),
    })
}

#[cfg(test)]
#[path = "gate_tests.rs"]
mod tests;
