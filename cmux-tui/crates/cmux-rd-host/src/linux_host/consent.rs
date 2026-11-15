//! Who may see this desktop: the same model as the Mac. The hub admits a viewer only with
//! the person's permission (`view`/`full` rows they granted serve at once; `ask` sends a
//! `session.request` to this host). This host never answers a request by itself: it records
//! it in the login session's private runtime directory, and only the person's
//! `cmux-rd linux-host approve|deny` answers it. This desktop's own consent (`consent.json`,
//! set at `enable`) may further refuse control, as the Mac's local consent does.

use super::identity::{read_private, write_private};
use crate::Res;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Requests the hub ends after 5 minutes without a decision; older ones are dropped here too.
pub const REQUEST_TTL_MS: u64 = 5 * 60 * 1000;

/// What this host does with a `session.request` push. There is no other variant on purpose:
/// an unknown viewer is never approved without the person.
#[derive(Debug, PartialEq, Eq)]
pub enum OnRequest {
    /// Record it for the person's `approve` or `deny`.
    AskThePerson,
}

pub fn on_request(_request: &Request) -> OnRequest {
    OnRequest::AskThePerson
}

/// A viewer's pending request (`session.request`).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub id: String,
    pub viewer_id: String,
    #[serde(default)]
    pub viewer_name: String,
    #[serde(default)]
    pub viewer_key_fingerprint: Option<String>,
    /// `view` or `full`.
    pub scope: String,
    #[serde(default)]
    pub received_ms: u64,
}

/// This desktop's own consent: which session scopes it serves. Default: view only; control
/// needs `enable --allow-control`.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq)]
pub struct LocalConsent {
    pub view: bool,
    pub full: bool,
}

impl Default for LocalConsent {
    fn default() -> Self {
        Self { view: true, full: false }
    }
}

impl LocalConsent {
    /// How a ticket with `scope` is served: `Some(view_only)`, or None when this desktop does
    /// not allow it (the session is ended unserved). An unknown scope is refused.
    /// `applies_input`: whether this host's capture can apply a viewer's input; one that
    /// cannot (the Wayland portal) serves an allowed `full` ticket view only.
    pub fn serve(self, scope: &str, applies_input: bool) -> Option<bool> {
        match scope {
            "view" if self.view => Some(true),
            "full" if self.full => Some(!applies_input),
            _ => None,
        }
    }

    /// An error when the file is missing: `enable` always writes it, so a desktop without one
    /// (deleted while the host runs) serves nothing.
    pub fn load(dir: &Path) -> Res<Self> {
        match read_private(&dir.join("consent.json"))? {
            Some(bytes) => Ok(serde_json::from_slice(&bytes)?),
            None => {
                Err("no consent.json: nothing is shared until `cmux-rd linux-host enable`".into())
            }
        }
    }

    pub fn save(&self, dir: &Path) -> Res<()> {
        write_private(&dir.join("consent.json"), &serde_json::to_vec_pretty(self)?)
    }
}

/// The pending requests file (`$XDG_RUNTIME_DIR/cmux-screen-host/requests.json`, 0600).
pub struct Pending<'a> {
    dir: &'a Path,
}

impl<'a> Pending<'a> {
    pub fn new(dir: &'a Path) -> Self {
        Self { dir }
    }

    /// The live requests (expired ones dropped).
    pub fn list(&self, now_ms: u64) -> Res<Vec<Request>> {
        let all: Vec<Request> = match read_private(&self.dir.join("requests.json"))? {
            Some(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            None => Vec::new(),
        };
        Ok(all.into_iter().filter(|r| r.received_ms + REQUEST_TTL_MS > now_ms).collect())
    }

    fn store(&self, list: &[Request]) -> Res<()> {
        write_private(&self.dir.join("requests.json"), &serde_json::to_vec_pretty(list)?)
    }

    pub fn add(&self, request: Request, now_ms: u64) -> Res<()> {
        let mut list = self.list(now_ms)?;
        list.retain(|r| r.id != request.id);
        list.push(request);
        self.store(&list)
    }

    pub fn remove(&self, id: &str, now_ms: u64) -> Res<Option<Request>> {
        let mut list = self.list(now_ms)?;
        let found = list.iter().position(|r| r.id == id).map(|i| list.remove(i));
        self.store(&list)?;
        Ok(found)
    }
}

/// Why `--scope full` is refused on a host whose capture applies no input.
const NO_INPUT_FULL: &str = "this desktop is captured through the Wayland portal, which applies no input: it is shared view only (approve with --scope view)";

/// The person's answer to a request, checked before it reaches the hub: only a recorded
/// request, a scope at most the requested one (`full` may be lowered to `view`, never
/// raised) and one this desktop's consent allows. A host whose capture applies no input
/// (`applies_input` false: the Wayland portal) offers `view` for a request for control and
/// refuses an explicit `--scope full`, so the hub never grants control it would not apply.
pub fn decision_scope(
    request: &Request,
    wanted: Option<&str>,
    consent: LocalConsent,
    applies_input: bool,
) -> Result<String, String> {
    let scope = wanted.unwrap_or(&request.scope);
    match (request.scope.as_str(), scope) {
        ("full", "full" | "view") | ("view", "view") => {}
        (asked, given) => {
            return Err(format!("scope {given} is not allowed for a request for {asked}"))
        }
    }
    if consent.serve(scope, applies_input).is_none() {
        return Err(format!("this desktop does not allow {scope} sessions (enable with --allow-control to allow full)"));
    }
    if scope == "full" && !applies_input {
        if wanted == Some("full") {
            return Err(NO_INPUT_FULL.to_owned());
        }
        return Ok("view".to_owned());
    }
    Ok(scope.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(scope: &str) -> Request {
        Request {
            id: "s1".into(),
            viewer_id: "v".into(),
            viewer_name: "Mac".into(),
            viewer_key_fingerprint: None,
            scope: scope.into(),
            received_ms: 1_000,
        }
    }

    #[test]
    fn a_request_is_never_answered_without_the_person() {
        assert_eq!(on_request(&request("view")), OnRequest::AskThePerson);
        assert_eq!(on_request(&request("full")), OnRequest::AskThePerson);
    }

    #[test]
    fn decisions_never_raise_the_scope_or_pass_local_consent() {
        let all = LocalConsent { view: true, full: true };
        assert_eq!(decision_scope(&request("full"), None, all, true).as_deref(), Ok("full"));
        assert_eq!(
            decision_scope(&request("full"), Some("view"), all, true).as_deref(),
            Ok("view")
        );
        assert!(decision_scope(&request("view"), Some("full"), all, true).is_err());
        assert!(decision_scope(&request("view"), Some("none"), all, true).is_err());
        let view_only = LocalConsent { view: true, full: false };
        assert!(decision_scope(&request("full"), None, view_only, true).is_err());
        assert_eq!(
            decision_scope(&request("full"), Some("view"), view_only, true).as_deref(),
            Ok("view")
        );
    }

    #[test]
    fn local_consent_maps_ticket_scopes() {
        assert_eq!(LocalConsent::default().serve("view", true), Some(true));
        assert_eq!(LocalConsent::default().serve("full", true), None);
        assert_eq!(LocalConsent { view: true, full: true }.serve("full", true), Some(false));
        assert_eq!(LocalConsent { view: true, full: false }.serve("full", true), None);
        assert_eq!(LocalConsent::default().serve("control", true), None);
    }

    #[test]
    fn a_host_that_applies_no_input_serves_and_offers_view_only() {
        // The Wayland portal capture drops every input event: a control session would
        // promise what it does not do.
        let all = LocalConsent { view: true, full: true };
        assert_eq!(all.serve("full", false), Some(true));
        assert_eq!(all.serve("view", false), Some(true));
        assert_eq!(LocalConsent::default().serve("full", false), None);
        // Approving a request for control offers view.
        assert_eq!(decision_scope(&request("full"), None, all, false).as_deref(), Ok("view"));
        assert_eq!(
            decision_scope(&request("full"), Some("view"), all, false).as_deref(),
            Ok("view")
        );
        let refused = decision_scope(&request("full"), Some("full"), all, false).unwrap_err();
        assert!(refused.contains("--scope view"), "{refused}");
    }

    #[test]
    fn pending_requests_expire_and_are_private() {
        let dir =
            std::env::temp_dir().join(format!("cmux-screen-host-pending-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let pending = Pending::new(&dir);
        pending.add(request("view"), 1_000).unwrap();
        assert_eq!(pending.list(2_000).unwrap().len(), 1);
        assert!(pending.list(1_000 + REQUEST_TTL_MS).unwrap().is_empty());
        use std::os::unix::fs::MetadataExt;
        assert_eq!(std::fs::metadata(dir.join("requests.json")).unwrap().mode() & 0o777, 0o600);
        assert_eq!(pending.remove("s1", 2_000).unwrap().map(|r| r.id), Some("s1".into()));
        assert!(pending.list(2_000).unwrap().is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
