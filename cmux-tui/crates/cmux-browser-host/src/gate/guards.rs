//! Guards that need more than a policy check before the call: cookie calls
//! follow the domain policy (main's BrowserReplCookieGuard), and captures
//! hide secret fields for their duration (main's BrowserReplCaptureMask).

use super::Gate;
use crate::protocol::{DriverError, ErrorCode};
use serde_json::{Value, json};
use std::sync::PoisonError;

/// Hides fields and text that hold a secret value: `-webkit-text-security`
/// and a transparent color, inline and important, so no author style wins.
/// Runs in the host world, which page script cannot reach; the page can
/// still change the DOM, which the held check below catches. Captures may
/// overlap: each has a token, and an element's own style comes back only
/// when the last capture that hid it ends. The marker comment stays first
/// (tests find the step by it).
const CAPTURE_MASK: &str = "/* cmux-capture-mask */ (values, token) => { \
    const g = globalThis; const st = g.__cmuxCaptureState || (g.__cmuxCaptureState = { saved: new Map(), runs: new Map() }); \
    const roots = (root, out) => { out.push(root); for (const el of root.querySelectorAll('*')) if (el.shadowRoot) roots(el.shadowRoot, out); return out; }; \
    const holds = (text) => !!text && values.some((v) => text.includes(v)); \
    const scan = () => { const found = new Set(); for (const root of roots(document, [])) { \
      for (const el of root.querySelectorAll('input, textarea')) if (el.type === 'password' || holds(el.value)) found.add(el); \
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT); \
      for (let n = walker.nextNode(); n; n = walker.nextNode()) if (n.parentElement && holds(n.data)) found.add(n.parentElement); } \
      return found; }; \
    const props = ['-webkit-text-security', 'color']; const mine = scan(); \
    for (const el of mine) { const s = st.saved.get(el); if (s) { s.count++; continue; } \
      st.saved.set(el, { count: 1, props: props.map((p) => [el.style.getPropertyValue(p), el.style.getPropertyPriority(p)]) }); \
      el.style.setProperty('-webkit-text-security', 'disc', 'important'); el.style.setProperty('color', 'transparent', 'important'); } \
    st.runs.set(token, { scan, mine, props }); return mine.size; }";

/// `true` while every element that holds a secret is still hidden, else
/// why not (never a value).
const CAPTURE_HELD: &str = "/* cmux-capture-held */ (token) => { const st = globalThis.__cmuxCaptureState; \
    const run = st && st.runs.get(token); if (!run) return 'the mask state is gone'; \
    for (const el of run.scan()) { if (!run.mine.has(el)) return 'a new element holds a secret'; const s = getComputedStyle(el); \
      const security = s.getPropertyValue('-webkit-text-security'); if (security !== 'disc') return 'text security is ' + security; \
      if (s.color !== 'rgba(0, 0, 0, 0)') return 'the text color is ' + s.color; } \
    return true; }";

/// Ends one capture's mask.
const CAPTURE_UNMASK: &str = "/* cmux-capture-unmask */ (token) => { const st = globalThis.__cmuxCaptureState; \
    const run = st && st.runs.get(token); if (!run) return 0; st.runs.delete(token); \
    for (const el of run.mine) { const s = st.saved.get(el); if (!s || --s.count > 0) continue; st.saved.delete(el); \
      run.props.forEach((p, i) => { el.style.removeProperty(p); if (s.props[i][0]) el.style.setProperty(p, s.props[i][0], s.props[i][1]); }); } \
    return run.mine.size; }";

/// Tokens that tell overlapping captures apart.
static CAPTURE_TOKEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

impl Gate {
    fn policy_active(&self) -> bool {
        let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
        policy.base().is_active() || policy.agent().is_active()
    }

    /// Refuses a cookie call the domain policy does not allow, before the
    /// driver sees it.
    pub(super) fn check_cookies(&self, method: &str, params: &Value) -> Result<(), DriverError> {
        if !method.starts_with("cookies.") || !self.policy_active() {
            return Ok(());
        }
        let refuse = |message: String| Err(DriverError::new(ErrorCode::Forbidden, message));
        let url_refusal = |url: &str| {
            self.policy.lock().unwrap_or_else(PoisonError::into_inner).navigation_refusal(url)
        };
        match method {
            "cookies.get" => {
                for url in params["urls"].as_array().into_iter().flatten().filter_map(Value::as_str)
                {
                    if let Some(reason) = url_refusal(url) {
                        return refuse(format!("cookies.get: {url} is blocked: {reason}"));
                    }
                }
            }
            "cookies.set" => {
                for cookie in params["cookies"].as_array().into_iter().flatten() {
                    let url = cookie["url"].as_str();
                    if let Some(url) = url
                        && let Some(reason) = url_refusal(url)
                    {
                        return refuse(format!("cookies.set: {url} is blocked: {reason}"));
                    }
                    let domain = match cookie["domain"].as_str() {
                        Some(domain) => domain.to_owned(),
                        None => url
                            .and_then(|url| url::Url::parse(url).ok())
                            .and_then(|url| url.host_str().map(str::to_owned))
                            .unwrap_or_default(),
                    };
                    let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
                    if let Some(reason) = policy.cookie_set_refusal(&domain) {
                        return refuse(format!(
                            "cookies.set: a cookie on {domain} is blocked: {reason}"
                        ));
                    }
                }
            }
            "cookies.clear" => {
                if let Some(domain) = params["domain"].as_str() {
                    let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
                    if let Some(reason) = policy.cookie_refusal(domain) {
                        return refuse(format!("cookies.clear: {domain} is blocked: {reason}"));
                    }
                }
                // The driver clears the tab's site; a tab on a blocked site
                // is refused. Without a tab the driver's scope is unknown
                // here, so the call fails closed while a policy is active.
                let Some(target) = params["targetId"].as_str() else {
                    return refuse(
                        "cookies.clear: name the tab (targetId) while a domain policy is active"
                            .into(),
                    );
                };
                let info = self.driver.call("tab.info", &json!({"targetId": target}))?;
                let url = info["url"].as_str().unwrap_or("");
                if let Some(reason) = url_refusal(url) {
                    return refuse(format!("cookies.clear: {url} is blocked: {reason}"));
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// Leaves out the cookies of blocked sites from a `cookies.get` result.
    pub(super) fn filter_cookies(&self, method: &str, result: Value) -> Value {
        if method != "cookies.get" || !self.policy_active() {
            return result;
        }
        let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
        let keep = |cookie: &Value| {
            policy.cookie_refusal(cookie["domain"].as_str().unwrap_or("")).is_none()
        };
        match result {
            Value::Array(list) => Value::Array(list.into_iter().filter(keep).collect()),
            Value::Object(mut object) => {
                if let Some(Value::Array(list)) = object.remove("cookies") {
                    object.insert(
                        "cookies".into(),
                        Value::Array(list.into_iter().filter(keep).collect()),
                    );
                }
                Value::Object(object)
            }
            other => other,
        }
    }

    /// `tab.screenshot` and `tab.pdf` while any secret exists: hide secret
    /// fields in every frame, capture, check that the page kept them
    /// hidden, restore. A capture the page could have unmasked is refused.
    pub(super) fn capture(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        let target = params.get("targetId").cloned().unwrap_or(Value::Null);
        let mut masker = self.masker();
        if let Some(tab) = target.as_str().and_then(|t| self.tab_secrets.masker(t)) {
            masker.merge(&tab);
        }
        let values = masker.capture_needles();
        if values.is_empty() {
            return self.driver.call(method, params);
        }
        let frames: Vec<Value> = match self.driver.call("frames.list", &json!({"targetId": target}))
        {
            Ok(Value::Array(list)) if !list.is_empty() => {
                list.iter().map(|frame| frame["frameId"].clone()).collect()
            }
            _ => vec![Value::Null],
        };
        let evaluate = |frame: &Value, source: &str, args: Value| {
            let mut call =
                json!({"targetId": target, "world": "host", "source": source, "args": args});
            if !frame.is_null() {
                call["frameId"] = frame.clone();
            }
            self.driver.call("frame.evaluate", &call)
        };
        let refused = |why: String| {
            DriverError::new(ErrorCode::Invalid, format!("{method}: {why}; the capture is refused"))
        };
        let token = CAPTURE_TOKEN.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut outcome = Ok(Value::Null);
        for frame in &frames {
            if let Err(error) = evaluate(frame, CAPTURE_MASK, json!([values, token])) {
                outcome = Err(refused(format!(
                    "secret fields could not be hidden ({})",
                    self.mask(&error.message)
                )));
                break;
            }
        }
        if outcome.is_ok() {
            outcome = self.driver.call(method, params);
        }
        if outcome.is_ok() {
            for frame in &frames {
                let why = match evaluate(frame, CAPTURE_HELD, json!([token])) {
                    Ok(Value::Bool(true)) => continue,
                    Ok(Value::String(why)) => why,
                    Ok(_) => "the check failed".to_owned(),
                    Err(error) => self.mask(&error.message),
                };
                outcome = Err(refused(format!(
                    "the page removed the secret mask during the capture ({why})"
                )));
                break;
            }
        }
        for frame in &frames {
            let _ = evaluate(frame, CAPTURE_UNMASK, json!([token]));
        }
        outcome
    }
}
