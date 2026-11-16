//! Who may see this desktop: the same model as the Mac. The hub admits a viewer only with
//! the person's permission (`view`/`full` rows they granted serve at once; `ask` sends a
//! `session.request` to this host). A viewer signed in to the account this desktop is enabled
//! for is the person themself (design D11): this host approves it with no prompt. Any other
//! request is recorded in the login session's private runtime directory, and only the
//! person's `cmux-rd linux-host approve|deny` answers it. This desktop's own consent
//! (`consent.json`, set at `enable`) may further refuse control, as the Mac's local consent does.

use super::identity::{read_private, write_private};
use crate::Res;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Requests the hub ends after 5 minutes without a decision; older ones are dropped here too.
pub const REQUEST_TTL_MS: u64 = 5 * 60 * 1000;

/// What this host does with a `session.request` push. Only the person's own account skips
/// them: another account, a shared link or shared access is never approved without the person.
#[derive(Debug, PartialEq, Eq)]
pub enum OnRequest {
    /// Record it for the person's `approve` or `deny`.
    AskThePerson,
    /// The viewer is signed in to this desktop's own account: approve it, no prompt.
    OwnAccount,
}

/// `own_user_id`: the account this desktop is enabled for (`account.json`, the hub session it
/// holds). Same account only on the hub's word: `access` and `viewerUserId` are set by the hub
/// from the viewer's verified session, never from what the viewer sends, and a request
/// without them (an older hub) asks.
pub fn on_request(request: &Request, own_user_id: Option<&str>) -> OnRequest {
    let own = own_user_id.filter(|u| !u.is_empty());
    if request.access.as_deref() == Some("account")
        && own.is_some()
        && request.viewer_user_id.as_deref() == own
    {
        OnRequest::OwnAccount
    } else {
        OnRequest::AskThePerson
    }
}

/// The scope this host grants its own account: what was asked, lowered to `view` when this
/// desktop's consent or capture does not allow control (Full Control still needs
/// `enable --allow-control`). None when this desktop serves nothing.
pub fn own_account_scope(
    request: &Request,
    consent: LocalConsent,
    applies_input: bool,
) -> Option<String> {
    decision_scope(request, None, consent, applies_input)
        .or_else(|_| decision_scope(request, Some("view"), consent, applies_input))
        .ok()
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
    /// How the hub admitted the viewer: `account` when it is signed in to this host's account.
    #[serde(default)]
    pub access: Option<String>,
    /// The account the hub verified for the viewer's session.
    #[serde(default)]
    pub viewer_user_id: Option<String>,
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
            access: None,
            viewer_user_id: None,
            received_ms: 1_000,
        }
    }

    /// A request as the hub pushes it: `access` and the viewer's verified account.
    fn request_from(access: &str, viewer_user_id: &str) -> Request {
        Request {
            access: Some(access.into()),
            viewer_user_id: Some(viewer_user_id.into()),
            ..request("full")
        }
    }

    const OWN: Option<&str> = Some("p:me");

    #[test]
    fn a_viewer_on_this_desktops_account_is_served_with_no_prompt() {
        assert_eq!(on_request(&request_from("account", "p:me"), OWN), OnRequest::OwnAccount);
        let view = Request { scope: "view".into(), ..request_from("account", "p:me") };
        assert_eq!(on_request(&view, OWN), OnRequest::OwnAccount);
    }

    #[test]
    fn a_viewer_on_another_account_still_asks() {
        assert_eq!(on_request(&request_from("account", "p:other"), OWN), OnRequest::AskThePerson);
        // The same user id under another auth project is another account.
        assert_eq!(on_request(&request_from("account", "q:me"), OWN), OnRequest::AskThePerson);
    }

    #[test]
    fn a_shared_link_still_asks() {
        // Even when the hub names this account as the one that opened the link.
        assert_eq!(on_request(&request_from("link", "p:me"), OWN), OnRequest::AskThePerson);
    }

    #[test]
    fn shared_access_still_asks() {
        assert_eq!(on_request(&request_from("shared", "p:me"), OWN), OnRequest::AskThePerson);
        assert_eq!(on_request(&request_from("shared", "p:other"), OWN), OnRequest::AskThePerson);
    }

    #[test]
    fn without_the_hubs_word_a_request_asks() {
        // An older hub sends neither field; nothing is assumed.
        assert_eq!(on_request(&request("view"), OWN), OnRequest::AskThePerson);
        let no_kind = Request { access: None, ..request_from("account", "p:me") };
        assert_eq!(on_request(&no_kind, OWN), OnRequest::AskThePerson);
        // A desktop that does not know its own account, or an empty one, never matches.
        assert_eq!(on_request(&request_from("account", "p:me"), None), OnRequest::AskThePerson);
        assert_eq!(on_request(&request_from("account", ""), Some("")), OnRequest::AskThePerson);
    }

    #[test]
    fn the_hubs_fields_parse_from_the_push() {
        let pushed = serde_json::json!({
            "id": "s1", "viewerId": "v", "viewerName": "Mac", "scope": "view",
            "access": "account", "viewerUserId": "p:me"
        });
        let r: Request = serde_json::from_value(pushed).unwrap();
        assert_eq!(on_request(&r, OWN), OnRequest::OwnAccount);
    }

    #[test]
    fn the_own_account_gets_control_only_with_this_desktops_consent() {
        let all = LocalConsent { view: true, full: true };
        let full = request_from("account", "p:me");
        assert_eq!(own_account_scope(&full, all, true).as_deref(), Some("full"));
        assert_eq!(
            own_account_scope(&full, LocalConsent::default(), true).as_deref(),
            Some("view")
        );
        // The Wayland portal applies no input: view.
        assert_eq!(own_account_scope(&full, all, false).as_deref(), Some("view"));
        let view = Request { scope: "view".into(), ..full.clone() };
        assert_eq!(own_account_scope(&view, all, true).as_deref(), Some("view"));
        let nothing = LocalConsent { view: false, full: false };
        assert_eq!(own_account_scope(&full, nothing, true), None);
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
