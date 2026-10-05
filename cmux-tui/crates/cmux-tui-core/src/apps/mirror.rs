//! The install mirror: a pure reducer over per-app install records (V9).
//!
//! `UserDO`/`TeamDO` will own installs; until that record syncs down, the
//! daemon's supervisor owns this local mirror (`apps.json`). Every change is
//! an [`Op`] with an idempotency key; [`reduce`] validates it against the
//! invariants and returns the next mirror plus the effects the owner must run
//! in the same commit (clear storage, stop the host, refresh grants).
//!
//! Invariants (checked by the property tests in `mirror_tests.rs`):
//! 1. hidden implies installed;
//! 2. a record that is not installed has no grants, is not enabled and not
//!    hidden (uninstall clears enable, hide, grants and, as an effect,
//!    storage, in one commit);
//! 3. grants are a subset of the scopes the manifest requests;
//! 4. replaying an op with the same key changes nothing;
//! 5. the revision grows by one per changing commit and never otherwise.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use serde::{Deserialize, Serialize};

use cmux_app_manifest::ScopeClass;

/// Applied idempotency keys kept for replay detection.
pub const APPLIED_KEYS: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Tier {
    FirstParty,
    Verified,
    Unverified,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Source {
    /// Installed for everyone by the deployment list.
    Default,
    /// Installed by the user.
    User,
    /// Shipped next to the daemon (sample apps), not installed by default.
    Bundled,
    /// A local development app (`local/…`).
    Local,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct HiddenAccess {
    pub cli: bool,
    pub mcp: bool,
    pub automations: bool,
}

impl Default for HiddenAccess {
    fn default() -> Self {
        Self { cli: true, mcp: true, automations: true }
    }
}

/// Who asked (OWNERSHIP-PRINCIPLES `origin`; absent on the wire = cli).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Origin {
    User,
    #[default]
    Cli,
    Mcp,
    Script,
    Remote,
}

/// One app's install record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub installed: bool,
    pub source: Source,
    pub enabled: bool,
    pub hidden: bool,
    #[serde(default)]
    pub hidden_access: HiddenAccess,
    pub sandboxed: bool,
    pub grants: BTreeSet<String>,
}

/// What the catalog knows about an app; the reducer needs it to apply tier rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Facts {
    pub tier: Tier,
    pub source: Source,
    /// `scopes` in the manifest (required).
    pub requested: BTreeSet<String>,
    /// `optionalScopes` in the manifest.
    pub optional: BTreeSet<String>,
}

impl Facts {
    fn allows(&self, scope: &str) -> bool {
        self.requested.contains(scope) || self.optional.contains(scope)
    }

    /// Whether an app of this tier may hold `scope` at all. Unverified apps
    /// never hold a restricted or server-only scope (scope-classes.json, the
    /// table the validator and the consent sheet use).
    fn tier_may_hold(&self, scope: &str) -> bool {
        self.tier != Tier::Unverified
            || cmux_app_manifest::scope_info(scope)
                .is_some_and(|info| info.class != ScopeClass::Restricted && !info.server_only)
    }

    /// Grants and sandbox at install time (plan section 10): first-party and
    /// Verified get their requested scopes; unverified starts sandboxed with
    /// its non-restricted read scopes only.
    pub fn install_defaults(&self) -> (BTreeSet<String>, bool) {
        // No tier gets an elevated scope at install or from the deployment
        // defaults; it needs an explicit user grant (the validator also keeps
        // elevated scopes out of `scopes`).
        let requested = self.requested.iter().filter(|s| !is_elevated(s));
        match self.tier {
            Tier::FirstParty | Tier::Verified => (requested.cloned().collect(), false),
            Tier::Unverified => (
                requested.filter(|s| is_read_scope(s) && self.tier_may_hold(s)).cloned().collect(),
                true,
            ),
        }
    }
}

/// Elevated scopes (scope-classes.json): never granted at install, for any
/// tier; only an explicit user grant (origin user) adds one.
pub fn is_elevated(scope: &str) -> bool {
    cmux_app_manifest::scope_info(scope).is_some_and(|info| info.class == ScopeClass::Elevated)
}

/// `<family>:read` and `integration:<provider>:read`.
pub fn is_read_scope(scope: &str) -> bool {
    scope.ends_with(":read")
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mirror {
    pub revision: u64,
    pub apps: BTreeMap<String, Record>,
    /// (key, fingerprint) of the latest applied ops, oldest first.
    #[serde(default)]
    pub applied: VecDeque<(String, String)>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetOp {
    pub key: String,
    pub app: String,
    #[serde(default)]
    pub origin: Origin,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_access: Option<HiddenAccess>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sandboxed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grant: Option<(String, bool)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    /// A deployment-list app seen for the first time: installed for
    /// everyone with its required scopes, no consent. Never re-installs an
    /// app the user removed (its record stays).
    Seed {
        app: String,
    },
    Set(SetOp),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// Delete the app's local storage (uninstall).
    ClearStorage(String),
    /// Stop the app's host (uninstall or disable).
    StopHost(String),
    /// Grants or sandbox changed: a running host restarts with the new grant.
    GrantsChanged(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub mirror: Mirror,
    pub effects: Vec<Effect>,
    /// The key was applied before; nothing changed.
    pub replayed: bool,
    pub changed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reject {
    UnknownApp,
    /// The change needs origin `user` (field name).
    Origin(&'static str),
    /// The scope is not in the manifest's scopes or optionalScopes.
    ScopeNotRequested(String),
    /// The app's tier may not hold the scope (restricted or server-only for
    /// an unverified app).
    ScopeRestricted(String),
    /// An elevated scope is granted only with origin user.
    ScopeElevated(String),
    /// The change needs an installed app.
    NotInstalled,
    /// The same key was used for a different op.
    KeyConflict,
    BadRequest(&'static str),
}

impl Reject {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnknownApp => "apps.unknown",
            Self::Origin(_) => "apps.origin",
            Self::ScopeNotRequested(_) => "apps.scope",
            Self::ScopeRestricted(_) => "apps.scope_restricted",
            Self::ScopeElevated(_) => "apps.scope_elevated",
            Self::NotInstalled => "apps.notInstalled",
            Self::KeyConflict => "idempotency.conflict",
            Self::BadRequest(_) => "bad-request",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Self::UnknownApp => "no such app".into(),
            Self::Origin(field) => format!("changing {field} needs a user action"),
            Self::ScopeNotRequested(scope) => format!("the app does not request {scope}"),
            Self::ScopeRestricted(scope) => {
                format!("{scope} is restricted: an unverified app cannot hold it")
            }
            Self::ScopeElevated(scope) => {
                format!("{scope} is elevated: only you can grant it, in the confirmation sheet")
            }
            Self::NotInstalled => "the app is not installed".into(),
            Self::KeyConflict => "this idempotency key was used for a different change".into(),
            Self::BadRequest(message) => (*message).into(),
        }
    }
}

fn fresh(facts: &Facts, source: Source) -> Record {
    let (grants, sandboxed) = facts.install_defaults();
    Record {
        installed: true,
        source,
        enabled: true,
        hidden: false,
        hidden_access: HiddenAccess::default(),
        sandboxed,
        grants,
    }
}

/// The record an app has before anything was recorded for it.
pub fn absent(source: Source, facts: Option<&Facts>) -> Record {
    Record {
        installed: false,
        source,
        enabled: false,
        hidden: false,
        hidden_access: HiddenAccess::default(),
        sandboxed: facts.is_some_and(|f| f.tier == Tier::Unverified),
        grants: BTreeSet::new(),
    }
}

/// Validates `op` against `mirror` and returns the next mirror and effects.
pub fn reduce(mirror: &Mirror, op: &Op, facts: Option<&Facts>) -> Result<Outcome, Reject> {
    match op {
        Op::Seed { app } => {
            let facts = facts.ok_or(Reject::UnknownApp)?;
            if mirror.apps.contains_key(app) {
                return Ok(unchanged(mirror, false));
            }
            let mut next = mirror.clone();
            let mut record = fresh(facts, Source::Default);
            // Default apps get their required scopes without consent, whatever
            // the tier; never an elevated one (that needs a user grant).
            record.grants = facts.requested.iter().filter(|s| !is_elevated(s)).cloned().collect();
            record.sandboxed = false;
            next.apps.insert(app.clone(), record);
            next.revision += 1;
            Ok(Outcome { mirror: next, effects: vec![], replayed: false, changed: true })
        }
        Op::Set(set) => reduce_set(mirror, set, facts),
    }
}

fn unchanged(mirror: &Mirror, replayed: bool) -> Outcome {
    Outcome { mirror: mirror.clone(), effects: vec![], replayed, changed: false }
}

fn fingerprint(set: &SetOp) -> String {
    serde_json::to_string(set).unwrap_or_default()
}

fn reduce_set(mirror: &Mirror, set: &SetOp, facts: Option<&Facts>) -> Result<Outcome, Reject> {
    if set.key.is_empty() || set.key.len() > 256 {
        return Err(Reject::BadRequest("idempotency_key must be 1 to 256 bytes"));
    }
    let print = fingerprint(set);
    if let Some((_, previous)) = mirror.applied.iter().find(|(key, _)| *key == set.key) {
        return if *previous == print {
            Ok(unchanged(mirror, true))
        } else {
            Err(Reject::KeyConflict)
        };
    }
    let current = mirror.apps.get(&set.app);
    let Some(facts) = facts else {
        // An app the catalog no longer has can only be uninstalled.
        let only_uninstall = set.installed == Some(false)
            && set.enabled.is_none()
            && set.hidden.is_none()
            && set.hidden_access.is_none()
            && set.sandboxed.is_none()
            && set.grant.is_none();
        let Some(current) = current.filter(|_| only_uninstall) else {
            return Err(Reject::UnknownApp);
        };
        if set.origin != Origin::User {
            return Err(Reject::Origin("installed"));
        }
        return Ok(commit(
            mirror,
            set,
            &print,
            current,
            absent(current.source, None),
            vec![Effect::StopHost(set.app.clone()), Effect::ClearStorage(set.app.clone())],
        ));
    };
    let before = current.cloned().unwrap_or_else(|| absent(facts.source, Some(facts)));
    let user = set.origin == Origin::User;
    if set.installed.is_some_and(|i| i != before.installed) && !user {
        return Err(Reject::Origin("installed"));
    }
    if let Some((scope, true)) = &set.grant
        && !user
        && is_elevated(scope)
    {
        return Err(Reject::ScopeElevated(scope.clone()));
    }
    if set.grant.is_some() && !user {
        return Err(Reject::Origin("grants"));
    }
    if set.sandboxed == Some(false) && before.sandboxed && !user {
        return Err(Reject::Origin("sandboxed"));
    }
    let installing = set.installed == Some(true) && !before.installed;
    let uninstalling = set.installed == Some(false) && before.installed;
    let mut effects = Vec::new();
    let mut record = if installing {
        let source = if facts.source == Source::Local { Source::Local } else { Source::User };
        fresh(facts, source)
    } else if uninstalling {
        effects.push(Effect::StopHost(set.app.clone()));
        effects.push(Effect::ClearStorage(set.app.clone()));
        absent(before.source, Some(facts))
    } else {
        before.clone()
    };
    let touches_installed_state = set.enabled.is_some()
        || set.hidden.is_some()
        || set.hidden_access.is_some()
        || set.sandboxed.is_some()
        || set.grant.is_some();
    if !record.installed && touches_installed_state {
        return Err(if uninstalling {
            Reject::BadRequest("an uninstall cannot change other fields")
        } else {
            Reject::NotInstalled
        });
    }
    if let Some(enabled) = set.enabled {
        if record.enabled && !enabled {
            effects.push(Effect::StopHost(set.app.clone()));
        }
        record.enabled = enabled;
    }
    if let Some(hidden) = set.hidden {
        record.hidden = hidden;
    }
    if let Some(access) = set.hidden_access {
        record.hidden_access = access;
    }
    if let Some(sandboxed) = set.sandboxed
        && sandboxed != record.sandboxed
    {
        record.sandboxed = sandboxed;
        effects.push(Effect::GrantsChanged(set.app.clone()));
    }
    if let Some((scope, granted)) = &set.grant {
        if !facts.allows(scope) {
            return Err(Reject::ScopeNotRequested(scope.clone()));
        }
        if *granted && !facts.tier_may_hold(scope) {
            return Err(Reject::ScopeRestricted(scope.clone()));
        }
        let changed = if *granted {
            record.grants.insert(scope.clone())
        } else {
            record.grants.remove(scope)
        };
        if changed {
            effects.push(Effect::GrantsChanged(set.app.clone()));
        }
    }
    Ok(commit(mirror, set, &print, &before, record, effects))
}

fn commit(
    mirror: &Mirror,
    set: &SetOp,
    print: &str,
    before: &Record,
    record: Record,
    effects: Vec<Effect>,
) -> Outcome {
    let mut next = mirror.clone();
    next.applied.push_back((set.key.clone(), print.to_string()));
    while next.applied.len() > APPLIED_KEYS {
        next.applied.pop_front();
    }
    let changed = *before != record || !mirror.apps.contains_key(&set.app) && record.installed;
    if changed {
        next.apps.insert(set.app.clone(), record);
        next.revision += 1;
    }
    Outcome { mirror: next, effects, replayed: false, changed }
}
