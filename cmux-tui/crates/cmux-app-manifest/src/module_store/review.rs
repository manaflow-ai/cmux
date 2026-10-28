//! Install review, approval and update decisions for a module.
//!
//! Rules: a module is a tab (a web URL, or an offline web page). It declares
//! no code, server, handle or power field. Its scopes come from a short list.
//! The user approves exactly the reviewed commit, tree digest and manifest;
//! any other bytes need a new review. An update never applies by itself.

use super::digest::{ModuleFile, TreeDigest};
use super::source::{GitSource, Pin};
use super::Refusal;
use crate::{Issue, ScopeClass};
use serde_json::Value;

/// `offline`: a bundled page with no network. `web`: a URL in the browser engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModuleKind {
    Web,
    Offline,
}

impl ModuleKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ModuleKind::Web => "web",
            ModuleKind::Offline => "offline",
        }
    }
}

/// One scope the module asks for, with its risk class and the reason it gave.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopeGrant {
    pub scope: String,
    pub class: ScopeClass,
    pub reason: String,
}

/// Everything the consent sheet shows, computed from the reviewed bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallPreview {
    pub id: String,
    pub name: String,
    pub version: String,
    pub source: GitSource,
    pub pin: Pin,
    pub resolved_commit: String,
    pub digest: String,
    pub manifest_sha256: String,
    pub kind: ModuleKind,
    /// Every origin the module may reach: its URL, declared origins, net hosts.
    pub origins: Vec<String>,
    pub scopes: Vec<ScopeGrant>,
    pub warnings: Vec<Issue>,
    pub files: Vec<ModuleFile>,
}

/// Reviews a module from its parsed manifest and its digested tree.
/// Every error is an issue; warnings ride in the preview.
pub fn review_install(
    _manifest: &Value,
    _source: &GitSource,
    _pin: &Pin,
    _resolved_commit: &str,
    _tree: &TreeDigest,
) -> Result<InstallPreview, Vec<Issue>> {
    Err(vec![Refusal::new("not.implemented", "review").issue("")])
}

/// The user's approval: exactly the reviewed source, commit, digest and manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Approval {
    pub source_key: String,
    pub resolved_commit: String,
    pub digest: String,
    pub manifest_sha256: String,
}

impl Approval {
    pub fn for_preview(_preview: &InstallPreview) -> Self {
        Self {
            source_key: String::new(),
            resolved_commit: String::new(),
            digest: String::new(),
            manifest_sha256: String::new(),
        }
    }

    /// `Ok` only when `preview` is the reviewed bytes. Checks, in order:
    /// `source.changed`, `pin.moved`, `digest.mismatch`, `manifest.changed`.
    pub fn covers(&self, _preview: &InstallPreview) -> Result<(), Refusal> {
        Err(Refusal::new("not.implemented", "approval"))
    }
}

/// Installed bytes must still hash to the recorded digest before they run.
pub fn check_installed(_recorded_digest: &str, _tree: &TreeDigest) -> Result<(), Refusal> {
    Err(Refusal::new("not.implemented", "installed check"))
}

/// What changed between two reviewed versions of one module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateReview {
    pub from_version: String,
    pub to_version: String,
    pub added_origins: Vec<String>,
    pub removed_origins: Vec<String>,
    pub added_scopes: Vec<ScopeGrant>,
    pub removed_scopes: Vec<String>,
    pub kind_changed: bool,
    pub added_files: Vec<String>,
    pub removed_files: Vec<String>,
    pub changed_files: Vec<String>,
    pub warnings: Vec<Issue>,
}

/// An update is never applied by the store: it is up to date, it needs the
/// user's approval (with the diff), or it is refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateDecision {
    UpToDate,
    NeedsApproval(UpdateReview),
    Refused(Refusal),
}

/// Decides an update from the installed preview to a newly reviewed one.
pub fn decide_update(_installed: &InstallPreview, _next: &InstallPreview) -> UpdateDecision {
    UpdateDecision::Refused(Refusal::new("not.implemented", "update"))
}
