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
use crate::secrets::Vault;
use crate::vm::VmHost;
use serde_json::{Value, json};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

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
        }
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
            let filter: crate::driver::RequestFilter = Arc::new(move |url: &str| {
                let parsed = url::Url::parse(url).ok()?;
                policy.lock().unwrap_or_else(PoisonError::into_inner).subresource_refusal(&parsed)
            });
            filter
        });
        self.driver.set_request_filter(filter);
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
        let text = self
            .vault
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .text_for_frame(&name, frame_url, now)
            .map_err(|e| Self::refuse(e.0))?;
        params[field] = Value::String(text);
        Ok(())
    }
}

impl VmHost for Gate {
    fn driver_call(&self, method: &str, params: Value) -> Result<Value, DriverError> {
        self.check(method, &params)?;
        let mut params = params;
        if matches!(method, "input.insertText" | "input.key") {
            self.resolve_secret(&mut params, "text")?;
        }
        match self.driver.call(method, &params) {
            Ok(value) => Ok(self.mask_value(&value)),
            Err(mut error) => {
                error.message = self.mask(&error.message);
                error.error_name = error.error_name.map(|name| self.mask(&name));
                error.data = error.data.map(|data| self.mask_value(&data));
                Err(error)
            }
        }
    }

    fn native(&self, name: &str, args: Value) -> Result<Value, String> {
        let arg = |i: usize| args.get(i).cloned().unwrap_or(Value::Null);
        match name {
            "secretSet" => {
                let secret_name = arg(0).as_str().unwrap_or("").to_owned();
                let value = arg(1).as_str().unwrap_or("").to_owned();
                let options = arg(2);
                let domains: Vec<String> = options["domains"]
                    .as_array()
                    .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                    .unwrap_or_default();
                let totp = options["totp"].as_bool().unwrap_or(false);
                if self
                    .vault
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .agent_known(&secret_name)
                    == Some(false)
                {
                    return Err(format!(
                        "secrets.set: {secret_name} is a user secret; agent code cannot replace it"
                    ));
                }
                self.vault
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .set(&secret_name, &value, &domains, totp, true)
                    .map_err(|e| e.0)?;
                Ok(json!({"__secret": secret_name}))
            }
            "secretList" => {
                let list = self.vault.lock().unwrap_or_else(PoisonError::into_inner).list();
                Ok(Value::Array(
                    list.into_iter()
                        .map(|s| json!({"name": s.name, "domains": s.domains, "totp": s.totp, "agentKnown": s.agent_known}))
                        .collect(),
                ))
            }
            "secretDelete" => {
                let secret_name = arg(0).as_str().unwrap_or("").to_owned();
                if self
                    .vault
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .agent_known(&secret_name)
                    == Some(false)
                {
                    return Err(format!(
                        "secrets.delete: {secret_name} is a user secret; agent code cannot delete it"
                    ));
                }
                Ok(json!(
                    self.vault.lock().unwrap_or_else(PoisonError::into_inner).delete(&secret_name)
                ))
            }
            "policyNarrow" => {
                // {allowed?: [..]|null, prohibited?: [..], blockIPAddresses?: bool, lock?: bool}
                let change = arg(0);
                let to_list = |v: &Value| -> Vec<String> {
                    v.as_array()
                        .map(|l| l.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                        .unwrap_or_default()
                };
                let mut policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
                let mut layer = policy.agent().clone();
                match change.get("allowed") {
                    Some(Value::Null) => layer.allowed = None,
                    Some(list) => {
                        layer.allowed = Some(parse_patterns(&to_list(list)).map_err(|e| e.0)?);
                    }
                    None => {}
                }
                if let Some(list) = change.get("prohibited") {
                    layer.prohibited = parse_patterns(&to_list(list)).map_err(|e| e.0)?;
                }
                if let Some(block) = change.get("blockIPAddresses").and_then(Value::as_bool) {
                    layer.block_ips = block;
                }
                let lock = change.get("lock").and_then(Value::as_bool).unwrap_or(false);
                policy.set(Writer::Agent, layer, lock).map_err(|e| e.0)?;
                let answer = effective(&policy);
                drop(policy);
                self.sync_request_filter();
                Ok(answer)
            }
            "policyGet" => {
                Ok(effective(&self.policy.lock().unwrap_or_else(PoisonError::into_inner)))
            }
            "policyLog" => {
                Ok(Value::Array(self.log.lock().unwrap_or_else(PoisonError::into_inner).clone()))
            }
            // The tab's own last after-commit block; none are made yet.
            "policyCheck" => Ok(Value::Null),
            other => Err(format!("unknown host function {other}")),
        }
    }
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
        "blockIPAddresses": base.block_ips || agent.block_ips,
        "locked": policy.locked(),
    })
}

#[cfg(test)]
#[path = "gate_tests.rs"]
mod tests;
