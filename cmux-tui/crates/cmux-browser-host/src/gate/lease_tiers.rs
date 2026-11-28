//! Browser grants (RFD 0125 D7.2) on the driver calls themselves, not only
//! on requests: a call that reads or acts on a page is checked against the
//! live leases at the moment it runs, on the page as it is now (a lease that
//! expired or was revoked after the page loaded reaches nothing), and with
//! the tier the call needs (a read lease never types, clicks, runs a script,
//! writes a cookie or sends a non-GET fetch). A commit lease that is the
//! only cover is spent by the one action it allowed (D7.4).
//!
//! Only while the session holds grants (`Policy::leases` is `Some`); a
//! session without one makes no extra call.

use super::Gate;
use crate::protocol::{DriverError, ErrorCode};
use cmux_browser_grants::Tier;
use serde_json::{Value, json};
use std::sync::PoisonError;

/// Reads the page as it is now (so a capture or an observe of a loaded
/// page is a read of its site, rechecked at the call).
const READS: &[&str] = &[
    "frame.observe",
    "frame.contentFrame",
    "frame.contentFrames",
    "frame.ownerBox",
    "tab.screenshot",
    "tab.pdf",
];

/// Acts on the page as it is now. `frame.evaluate` runs arbitrary script,
/// which can submit a form or send a signed-in request, so it is an act.
const ACTS: &[&str] = &["frame.evaluate", "dialog.respond"];

/// The frame location, read in the host world (page script cannot reach it).
const FRAME_URL: &str = "() => String(location.href)";

/// What `net.fetch` needs: GET and HEAD only read.
fn fetch_tier(params: &Value) -> Tier {
    let method = params.get("method").and_then(Value::as_str).unwrap_or("GET");
    if method.eq_ignore_ascii_case("GET") || method.eq_ignore_ascii_case("HEAD") {
        Tier::Read
    } else {
        Tier::Act
    }
}

fn refuse(method: &str, url: &str, reason: &str) -> DriverError {
    DriverError::new(ErrorCode::Forbidden, format!("{method}: {url} is blocked: {reason}"))
}

impl Gate {
    fn holds_leases(&self) -> bool {
        self.policy.lock().unwrap_or_else(PoisonError::into_inner).leases().is_some()
    }

    /// Allows one call needing `needed` on `url`, spending a commit lease
    /// that is its only cover.
    fn authorize_url(&self, method: &str, url: &str, needed: Tier) -> Result<(), DriverError> {
        let Ok(parsed) = url::Url::parse(url) else {
            return Err(refuse(method, url, "not a valid URL"));
        };
        self.policy
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .authorize_lease(&parsed, needed)
            .map_err(|reason| refuse(method, url, &reason))
    }

    /// Where the call lands now: the frame it names (read in the host
    /// world) or the tab's top document. Fails closed when the host cannot
    /// tell.
    fn current_url(&self, method: &str, params: &Value) -> Result<String, DriverError> {
        let unknown = || {
            DriverError::new(
                ErrorCode::Forbidden,
                format!(
                    "{method}: the page's site cannot be verified against the session's grants"
                ),
            )
        };
        let target = params.get("targetId").filter(|t| t.is_string()).ok_or_else(unknown)?;
        let info = self.driver.call("tab.info", &json!({"targetId": target}))?;
        let top = info.get("url").and_then(Value::as_str).ok_or_else(unknown)?.to_owned();
        let Some(frame) = params.get("frameId").filter(|f| !f.is_null()) else {
            return Ok(top);
        };
        let probe = json!({
            "targetId": target, "frameId": frame, "world": "host", "source": FRAME_URL, "args": []
        });
        match self.driver.call("frame.evaluate", &probe) {
            Ok(Value::String(url)) => Ok(url),
            _ => Err(unknown()),
        }
    }

    /// The lease and tier check for one call, before the driver runs it.
    pub(super) fn check_lease_tier(&self, method: &str, params: &Value) -> Result<(), DriverError> {
        if !self.holds_leases() {
            return Ok(());
        }
        let page_tier = if method.starts_with("input.") || ACTS.contains(&method) {
            Some(Tier::Act)
        } else if READS.contains(&method) {
            Some(Tier::Read)
        } else {
            None
        };
        if let Some(needed) = page_tier {
            let url = self.current_url(method, params)?;
            return self.authorize_url(method, &url, needed);
        }
        match method {
            "net.fetch" => {
                let url = params.get("url").and_then(Value::as_str).unwrap_or("");
                self.authorize_url(method, url, fetch_tier(params))
            }
            "cookies.set" => {
                for cookie in params["cookies"].as_array().into_iter().flatten() {
                    let url = match (cookie["url"].as_str(), cookie["domain"].as_str()) {
                        (Some(url), _) => url.to_owned(),
                        (None, Some(domain)) => {
                            format!("https://{}/", domain.trim().trim_start_matches('.'))
                        }
                        (None, None) => return Err(refuse(method, "", "the cookie names no site")),
                    };
                    self.authorize_url(method, &url, Tier::Act)?;
                }
                Ok(())
            }
            "cookies.clear" => {
                let url = match params["domain"].as_str() {
                    Some(domain) => format!("https://{}/", domain.trim().trim_start_matches('.')),
                    None => self.current_url(method, params)?,
                };
                self.authorize_url(method, &url, Tier::Act)
            }
            // Restoring cookies writes sign-ins whose sites the call does not
            // name up front: not while the session borrows the person's.
            "cookies.restore" => Err(DriverError::new(
                ErrorCode::Forbidden,
                "cookies.restore: not available while the session holds browser grants",
            )),
            _ => Ok(()),
        }
    }
}
