//! Install review, approval and update decisions for a module.
//!
//! Rules (threat model: plans/cmux-next/module-store-threat-model.md):
//! - A module is a tab: a web URL, or an offline page in `cmux.pane/1`.
//! - It declares no code, server, handle, requirement or power field.
//! - Its scopes come from a short list: storage, embed, and net to a named host.
//! - Every origin it can reach is listed before install.
//! - The user approves exactly the reviewed source, commit, tree digest and
//!   manifest. Any other bytes need a new review.
//! - An update never applies by itself. It is up to date, it needs approval
//!   with a diff, or it is refused.

use super::Refusal;
use super::digest::{ModuleFile, TreeDigest};
use super::fetch::is_full_sha;
use super::source::{GitSource, Pin, is_public_host};
use crate::issue::escape;
use crate::{Issue, ScopeClass, is_valid, scope_info, validate_manifest};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

/// Publisher names a third party may not claim.
const RESERVED_PUBLISHERS: &[&str] =
    &["cmux", "manaflow", "manaflow-ai", "local", "apple", "system", "official", "first-party"];
/// Top-level manifest fields that carry code, power or cmux surface. A git
/// module declares none of them in v1.
const FORBIDDEN_FIELDS: &[&str] = &[
    "server",
    "binaries",
    "handles",
    "requires",
    "contributes",
    "catalog",
    "cli",
    "consumes",
    "serves",
    "documents",
    "openWith",
    "optionalScopes",
    "activation",
    "variants",
    "drag",
    "drop",
    "lifecycle",
    "settings",
    "x-cmux-devOnly",
];
/// Keys a `cmux.pane/1` implementation may carry: a web page, and labels only.
const PANE_KEYS: &[&str] = &["web", "title", "symbol", "types"];
/// The scopes a git module may ask for in v1.
const ALLOWED_SCOPES: &[&str] = &["storage:local", "storage:synced", "embed:run"];
const PANE_INTERFACE: &str = "cmux.pane/1";
const MANIFEST_FILES: &[&str] = &["cmux-app.json", "cmux-app.v2.json"];

/// `web`: a URL in the browser engine with its own profile. `offline`: a
/// bundled page with no network.
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
    /// Every origin the module may reach: its URL, its declared origins and its net hosts.
    pub origins: Vec<String>,
    pub scopes: Vec<ScopeGrant>,
    pub warnings: Vec<Issue>,
    pub files: Vec<ModuleFile>,
}

/// Reviews a module from its parsed manifest and its digested tree. The
/// caller parses the same manifest file it digested (`cmux-app.json` or
/// `cmux-app.v2.json`); the tree must contain that file. Every problem is
/// reported at once; warnings ride in the preview.
pub fn review_install(
    manifest: &Value,
    source: &GitSource,
    pin: &Pin,
    resolved_commit: &str,
    tree: &TreeDigest,
) -> Result<InstallPreview, Vec<Issue>> {
    // The git source is the repository. The manifest's `repository` field is
    // informational for git modules (the store's GitHub-only rule does not
    // apply, so GitLab and other hosts work), and it is not checked here.
    let mut checked = manifest.clone();
    if let Some(object) = checked.as_object_mut() {
        object.remove("repository");
    }
    let mut issues: Vec<Issue> = validate_manifest(&checked)
        .into_iter()
        .filter(|i| i.code != "repository.required")
        .collect();
    let mut warnings: Vec<Issue> = Vec::new();

    if !is_full_sha(resolved_commit) {
        issues.push(
            Refusal::new("commit.invalid", "the resolved commit is not a full SHA").issue(""),
        );
    }
    if let Pin::Commit(commit) = pin
        && commit != resolved_commit
    {
        issues.push(
            Refusal::new(
                "pin.moved",
                format!("pinned to {commit}, but the source resolved to {resolved_commit}"),
            )
            .issue(""),
        );
    }
    if !MANIFEST_FILES.iter().any(|f| tree.has_file(f)) {
        issues.push(
            Refusal::new("manifest.missing", "the module tree has no cmux-app.json").issue(""),
        );
    }

    let id = manifest.get("id").and_then(Value::as_str).unwrap_or("");
    let publisher = id.split('/').next().unwrap_or("");
    let owner = source.owner();
    if publisher != owner {
        issues.push(
            Refusal::new(
                "identity.publisherMismatch",
                format!(
                    "{id:?} claims publisher {publisher:?}, but the repository owner is {owner:?}"
                ),
            )
            .issue("/id"),
        );
    }
    if RESERVED_PUBLISHERS.contains(&publisher) {
        issues.push(
            Refusal::new("identity.reserved", format!("{publisher:?} is a reserved publisher"))
                .issue("/id"),
        );
    }

    if manifest.pointer("/presentation/tab").and_then(Value::as_bool) != Some(true) {
        issues.push(
            Refusal::new("module.notATab", "a module is a tab: set presentation.tab to true")
                .issue("/presentation/tab"),
        );
    }

    for field in FORBIDDEN_FIELDS {
        if manifest.get(*field).is_some() {
            issues.push(not_allowed(&format!("/{field}"), field));
        }
    }
    if manifest.pointer("/runtime/main").is_some() {
        issues.push(not_allowed("/runtime/main", "runtime.main (code)"));
    }
    if manifest.pointer("/runtime/web/csp").is_some() {
        issues.push(not_allowed("/runtime/web/csp", "a custom content security policy"));
    }
    if let Some(implements) = manifest.get("implements").and_then(Value::as_object) {
        for (name, implementation) in implements {
            let at = format!("/implements/{}", escape(name));
            if name.as_str() != PANE_INTERFACE {
                issues.push(not_allowed(&at, name));
                continue;
            }
            for key in implementation.as_object().into_iter().flat_map(|o| o.keys()) {
                if !PANE_KEYS.contains(&key.as_str()) {
                    issues.push(not_allowed(&format!("{at}/{}", escape(key)), key));
                }
            }
        }
    }

    let web_url = manifest.pointer("/presentation/web/url").and_then(Value::as_str);
    let page = manifest.pointer("/implements/cmux.pane~11/web").is_some();
    let kind = if web_url.is_some() {
        Some(ModuleKind::Web)
    } else if page {
        Some(ModuleKind::Offline)
    } else {
        issues.push(
            Refusal::new(
                "module.noContent",
                "a module needs a web URL or an offline page (cmux.pane/1)",
            )
            .issue("/presentation"),
        );
        None
    };

    let mut origins: Vec<String> = Vec::new();
    if let Some(url) = web_url {
        match origin_of(url) {
            Ok(origin) => push_unique(&mut origins, origin),
            Err(refusal) => issues.push(refusal.issue("/presentation/web/url")),
        }
    }
    let declared = manifest.pointer("/presentation/web/origins").and_then(Value::as_array);
    for (i, value) in declared.into_iter().flatten().enumerate() {
        let at = format!("/presentation/web/origins/{i}");
        match value.as_str().map(origin_of) {
            Some(Ok(origin)) => push_unique(&mut origins, origin),
            Some(Err(refusal)) => issues.push(refusal.issue(&at)),
            None => {
                issues.push(Refusal::new("origin.invalid", "an origin is not a string").issue(&at));
            }
        }
    }

    let mut grants: Vec<ScopeGrant> = Vec::new();
    if let Some(scopes) = manifest.get("scopes").and_then(Value::as_object) {
        for (scope, reason) in scopes {
            let at = format!("/scopes/{}", escape(scope));
            let allowed = ALLOWED_SCOPES.contains(&scope.as_str()) || scope.starts_with("net:");
            if !allowed {
                issues.push(
                    Refusal::new(
                        "scope.notAllowed",
                        format!("{scope:?} is not available to git modules in v1"),
                    )
                    .issue(&at),
                );
                continue;
            }
            if let Some(host) = scope.strip_prefix("net:") {
                match origin_of(&format!("https://{host}")) {
                    Ok(origin) => push_unique(&mut origins, origin),
                    Err(refusal) => issues.push(refusal.issue(&at)),
                }
            }
            match scope_info(scope) {
                Some(info) => {
                    if info.class == ScopeClass::Sensitive {
                        warnings.push(Issue::warning(
                            at.clone(),
                            "scope.sensitive",
                            format!("{scope} is sensitive: review its reason before you approve"),
                        ));
                    }
                    grants.push(ScopeGrant {
                        scope: scope.clone(),
                        class: info.class,
                        reason: reason.as_str().unwrap_or("").to_string(),
                    });
                }
                None => issues.push(
                    Refusal::new("scope.unknown", format!("{scope:?} is not a scope cmux knows"))
                        .issue(&at),
                ),
            }
        }
    }

    if !is_valid(&issues) {
        return Err(issues);
    }
    let Some(kind) = kind else { return Err(issues) };

    warnings.extend(issues.iter().filter(|i| i.severity == crate::Severity::Warning).cloned());
    if !origins.is_empty() {
        warnings.push(Issue::warning(
            "/presentation/web",
            "origins.network",
            format!("the module may contact {} origin(s): {}", origins.len(), origins.join(", ")),
        ));
    }
    if !source.is_known_forge() {
        warnings.push(Issue::warning(
            "",
            "source.unknownHost",
            format!("{} is not a well-known git host", source.host()),
        ));
    }

    let manifest_sha256 =
        hex::encode(Sha256::digest(serde_json::to_vec(manifest).unwrap_or_default()));
    Ok(InstallPreview {
        id: id.to_string(),
        name: manifest.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
        version: manifest.get("version").and_then(Value::as_str).unwrap_or("").to_string(),
        source: source.clone(),
        pin: pin.clone(),
        resolved_commit: resolved_commit.to_string(),
        digest: tree.digest().to_string(),
        manifest_sha256,
        kind,
        origins,
        scopes: grants,
        warnings,
        files: tree.files().to_vec(),
    })
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
    pub fn for_preview(preview: &InstallPreview) -> Self {
        Self {
            source_key: preview.source.key(),
            resolved_commit: preview.resolved_commit.clone(),
            digest: preview.digest.clone(),
            manifest_sha256: preview.manifest_sha256.clone(),
        }
    }

    /// `Ok` only when `preview` is the reviewed bytes. Checks, in order:
    /// `source.changed`, `pin.moved`, `digest.mismatch`, `manifest.changed`.
    pub fn covers(&self, preview: &InstallPreview) -> Result<(), Refusal> {
        if self.source_key != preview.source.key() {
            return Err(Refusal::new("source.changed", "the source is not the one you approved"));
        }
        if self.resolved_commit != preview.resolved_commit {
            return Err(Refusal::new(
                "pin.moved",
                format!(
                    "you approved {}, the source now resolves to {}",
                    self.resolved_commit, preview.resolved_commit
                ),
            ));
        }
        if self.digest != preview.digest {
            return Err(Refusal::new(
                "digest.mismatch",
                "the files differ from the ones you approved",
            ));
        }
        if self.manifest_sha256 != preview.manifest_sha256 {
            return Err(Refusal::new(
                "manifest.changed",
                "the manifest differs from the one you approved",
            ));
        }
        Ok(())
    }
}

/// Installed bytes must still hash to the recorded digest before they run.
pub fn check_installed(recorded_digest: &str, tree: &TreeDigest) -> Result<(), Refusal> {
    if recorded_digest == tree.digest() {
        Ok(())
    } else {
        Err(Refusal::new(
            "digest.tampered",
            "the installed files no longer match the approved digest; the module will not run",
        ))
    }
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
    NeedsApproval(Box<UpdateReview>),
    Refused(Refusal),
}

/// Decides an update from the installed preview to a newly reviewed one.
pub fn decide_update(installed: &InstallPreview, next: &InstallPreview) -> UpdateDecision {
    if installed.id != next.id {
        return UpdateDecision::Refused(Refusal::new(
            "identity.changed",
            "the module id changed; install it as a new module",
        ));
    }
    if installed.source.key() != next.source.key() {
        return UpdateDecision::Refused(Refusal::new(
            "source.changed",
            "the repository changed; review and install it again",
        ));
    }
    if installed.resolved_commit == next.resolved_commit {
        if installed.digest == next.digest && installed.manifest_sha256 == next.manifest_sha256 {
            return UpdateDecision::UpToDate;
        }
        return UpdateDecision::Refused(Refusal::new(
            "digest.mismatch",
            "the same commit has different bytes; the source is not what it was",
        ));
    }
    UpdateDecision::NeedsApproval(Box::new(review_update(installed, next)))
}

fn review_update(installed: &InstallPreview, next: &InstallPreview) -> UpdateReview {
    let added_origins: Vec<String> =
        next.origins.iter().filter(|o| !installed.origins.contains(*o)).cloned().collect();
    let removed_origins: Vec<String> =
        installed.origins.iter().filter(|o| !next.origins.contains(*o)).cloned().collect();
    let added_scopes: Vec<ScopeGrant> = next
        .scopes
        .iter()
        .filter(|g| !installed.scopes.iter().any(|h| h.scope == g.scope))
        .cloned()
        .collect();
    let removed_scopes: Vec<String> = installed
        .scopes
        .iter()
        .filter(|g| !next.scopes.iter().any(|h| h.scope == g.scope))
        .map(|g| g.scope.clone())
        .collect();
    let old_files: BTreeMap<&str, &ModuleFile> =
        installed.files.iter().map(|f| (f.path.as_str(), f)).collect();
    let new_files: BTreeMap<&str, &ModuleFile> =
        next.files.iter().map(|f| (f.path.as_str(), f)).collect();
    let added_files: Vec<String> =
        new_files.keys().filter(|p| !old_files.contains_key(*p)).map(|p| p.to_string()).collect();
    let removed_files: Vec<String> =
        old_files.keys().filter(|p| !new_files.contains_key(*p)).map(|p| p.to_string()).collect();
    let changed_files: Vec<String> = new_files
        .iter()
        .filter(|(p, f)| {
            old_files.get(*p).is_some_and(|o| o.sha256 != f.sha256 || o.executable != f.executable)
        })
        .map(|(p, _)| p.to_string())
        .collect();

    let mut warnings = Vec::new();
    if semver_key(&next.version) < semver_key(&installed.version) {
        warnings.push(Issue::warning(
            "/version",
            "update.downgrade",
            format!("{} is older than the installed {}", next.version, installed.version),
        ));
    }
    if !added_origins.is_empty() {
        warnings.push(Issue::warning(
            "/presentation/web",
            "update.origins",
            format!("the update adds origins: {}", added_origins.join(", ")),
        ));
    }
    for grant in &added_scopes {
        if grant.class != ScopeClass::Standard {
            warnings.push(Issue::warning(
                "/scopes",
                "update.sensitiveScope",
                format!("the update asks for {}", grant.scope),
            ));
        }
    }
    UpdateReview {
        from_version: installed.version.clone(),
        to_version: next.version.clone(),
        added_origins,
        removed_origins,
        added_scopes,
        removed_scopes,
        kind_changed: installed.kind != next.kind,
        added_files,
        removed_files,
        changed_files,
        warnings,
    }
}

fn not_allowed(path: &str, what: &str) -> Issue {
    Refusal::new("module.notAllowed", format!("a git module may not declare {what} in v1"))
        .issue(path)
}

/// `https://host` for a public, non-wildcard host with no port or credentials.
fn origin_of(url: &str) -> Result<String, Refusal> {
    let rest = url
        .strip_prefix("https://")
        .ok_or_else(|| Refusal::new("origin.scheme", format!("{url:?} is not an https origin")))?;
    let host = rest.split('/').next().unwrap_or("");
    if host.contains('*') {
        return Err(Refusal::new(
            "origin.wildcard",
            format!("{host:?}: wildcard origins are not allowed"),
        ));
    }
    if host.contains('@') {
        return Err(Refusal::new("origin.credentials", "an origin must not carry credentials"));
    }
    if host.contains(':') {
        return Err(Refusal::new(
            "origin.port",
            format!("{host:?}: ports are not allowed in origins"),
        ));
    }
    if !is_public_host(host) {
        return Err(Refusal::new("origin.host", format!("{host:?} is not a public host")));
    }
    Ok(format!("https://{}", host.to_ascii_lowercase()))
}

fn push_unique(list: &mut Vec<String>, item: String) {
    if !list.contains(&item) {
        list.push(item);
    }
}

/// `major.minor.patch` for ordering; a pre-release tag does not count.
fn semver_key(version: &str) -> (u64, u64, u64) {
    let core = version.split(['-', '+']).next().unwrap_or("");
    let mut parts = core.split('.').map(|p| p.parse::<u64>().unwrap_or(0));
    (parts.next().unwrap_or(0), parts.next().unwrap_or(0), parts.next().unwrap_or(0))
}
