//! Who may see this desktop: the same model as the Mac. The hub admits a viewer only with
//! the person's permission (`view`/`full` rows they granted serve at once; `ask` sends a
//! `session.request` to this host). This host never answers a request by itself: it records
//! it in the login session's private runtime directory, and only the person's
//! `approve|deny` of the host command answers it. This desktop's own consent (`consent.json`,
//! set at `enable`) may further refuse control, as the Mac's local consent does.

use crate::Res;
use cmux_hub_host::identity::{read_private, write_private};
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

/// This desktop's own consent: which session scopes it serves. `enable` writes view and control:
/// the person joined this desktop to their own account, so their devices view and control it with no
/// prompt here (`enable --view-only` keeps control off). `Default` is view only.
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
                Err(format!("no consent.json: nothing is shared until `{} enable`", super::COMMAND)
                    .into())
            }
        }
    }

    pub fn save(&self, dir: &Path) -> Res<()> {
        write_private(&dir.join("consent.json"), &serde_json::to_vec_pretty(self)?)
    }
}

/// The pending requests file (`requests.json` in `identity::runtime_dir`, this user's only).
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
const NO_INPUT_FULL: &str = "this desktop is captured through the Wayland portal, which has no keyboard and pointer grant (`cmux-rd linux-host grant --control` asks for it once): it is shared view only (approve with --scope view)";

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
        return Err(format!("this desktop does not allow {scope} sessions (enable without --view-only to allow full)"));
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
#[path = "consent_tests.rs"]
mod tests;
