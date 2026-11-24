//! Old against new, in both directions, for every cmux wire protocol: acpmux (JSON-RPC between
//! the app, the phone and acpmux peers), cmux-mobile-link (the phone link) and cmux-remote (the
//! daemon carrier).
//!
//! Leo, 2026-11-24: "of course acpmux/cmux protocols need to be able to work in lockstep with
//! these and improve ever further". A transport change ships to one end before the other (a
//! NIGHTLY Mac with last week's phone, a peer that has not updated), so every message one side
//! starts sending must be one the other side asked for.
//!
//! Three pieces:
//!
//! - A [`Manifest`] per protocol, committed at `cmux-tui/spec/wire/<protocol>.json` and printed by
//!   the protocol's own crate from its registries (a snapshot test keeps it current). It names every
//!   wire name the protocol speaks ([`WireName`] forms: `method:`, `notify:`, `param:`, `field:`,
//!   `frame:`, `service:`, `control:`, `event:`) and which capability gates each one. Names that
//!   predate capability gating are `legacy`.
//! - [`check`]: the base revision's manifest against the head's. A name the head adds must sit under
//!   a capability the base did not have (so an old peer never advertises it and a new sender never
//!   sends it there); a capability's contract never changes under the same id; a capability, legacy
//!   name or hard version the base had never disappears unless the head retires it with a reason.
//!   `wire-lockstep-check` runs it in CI against the PR's base (`git show BASE:path`).
//! - [`OldPeer`] and [`Tap`]: the run-time half. A protocol's lockstep test drives its new code
//!   against a peer that knows only the base manifest (advertises only the base capabilities and
//!   refuses any other name as the old build would), records every name each side put on the wire,
//!   and fails on a one-sided message: a name sent to a peer that never said it knows it, or a name
//!   sent that the manifest does not declare at all.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

/// The manifest format this crate reads and writes.
pub const FORMAT: u32 = 1;

/// The name kinds a manifest may hold, as the prefix before `:`.
pub const KINDS: &[&str] =
    &["method", "notify", "param", "field", "frame", "service", "control", "event", "header"];

/// One wire name, `kind:rest` (for example `method:_acpmux/usage`, `param:_acpmux/kill#ifIdle`,
/// `frame:deflated-data=5`, `service:_link.park`).
pub type WireName = String;

/// What one protocol speaks, at one revision.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// `acpmux`, `mobile-link` or `cmux-remote`.
    pub protocol: String,
    /// [`FORMAT`].
    pub format: u32,
    /// Where the capabilities are exchanged, for a reader (`initialize _meta.acpmux.capabilities`).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub negotiated_in: String,
    /// Names spoken unconditionally because they predate capability gating. Never grows.
    #[serde(default)]
    pub legacy: BTreeSet<WireName>,
    /// Capability id to the names it gates. An id names one contract: its set never changes.
    #[serde(default)]
    pub capabilities: BTreeMap<String, BTreeSet<WireName>>,
    /// Hard version numbers on the wire (a frame header byte), by name.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub versions: BTreeMap<String, u32>,
    /// For each hard version, every value this build still decodes (must include the base's).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub accepts: BTreeMap<String, BTreeSet<u32>>,
    /// Capability ids and legacy names this revision stopped serving on purpose, with the reason
    /// and the date (old peers that still use them get the refusal the reason names).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub retired: BTreeMap<String, String>,
}

impl Manifest {
    pub fn new(protocol: &str, negotiated_in: &str) -> Self {
        Self {
            protocol: protocol.to_owned(),
            format: FORMAT,
            negotiated_in: negotiated_in.to_owned(),
            ..Self::default()
        }
    }

    /// Every name this revision speaks, gated or not.
    pub fn names(&self) -> BTreeSet<&str> {
        self.legacy.iter().chain(self.capabilities.values().flatten()).map(String::as_str).collect()
    }

    /// The capabilities that gate `name` (empty for a legacy or unknown name).
    pub fn gates(&self, name: &str) -> Vec<&str> {
        self.capabilities
            .iter()
            .filter(|(_, names)| names.contains(name))
            .map(|(id, _)| id.as_str())
            .collect()
    }

    /// Parses a committed manifest.
    pub fn from_json(text: &str) -> Result<Self, String> {
        let manifest: Self = serde_json::from_str(text).map_err(|e| e.to_string())?;
        if manifest.format != FORMAT {
            return Err(format!("manifest format {} (this build reads {FORMAT})", manifest.format));
        }
        Ok(manifest)
    }

    /// The committed form: sorted, two-space pretty JSON with a trailing newline, so a snapshot
    /// test compares bytes.
    pub fn to_json(&self) -> String {
        let mut text = serde_json::to_string_pretty(self).unwrap_or_default();
        text.push('\n');
        text
    }

    /// Shape errors a protocol's snapshot test should fail on: a name of an unknown kind, an empty
    /// capability, an accepted-version list without the current version.
    pub fn validate(&self) -> Vec<String> {
        let mut errors = Vec::new();
        for name in self.names() {
            let kind = name.split_once(':').map(|(kind, _)| kind);
            if !kind.is_some_and(|kind| KINDS.contains(&kind)) {
                errors.push(format!("{name}: not `kind:name` with kind one of {KINDS:?}"));
            }
        }
        for (id, names) in &self.capabilities {
            if names.is_empty() {
                errors.push(format!("capability {id} gates no wire name"));
            }
        }
        for (key, version) in &self.versions {
            if let Some(accepts) = self.accepts.get(key)
                && !accepts.contains(version)
            {
                errors.push(format!("{key}: accepts {accepts:?} lacks the current {version}"));
            }
        }
        errors
    }
}

/// One way a head revision would break an old peer, or an old peer would break it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Finding {
    pub protocol: String,
    pub rule: Rule,
    pub subject: String,
    pub detail: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Rule {
    /// A new name is not behind a capability the base lacked: the new side sends it to old peers.
    UngatedName,
    /// The legacy (ungated) set grew.
    LegacyGrew,
    /// A capability id kept its name but changed what it gates.
    ContractChanged,
    /// A capability the base served is gone, unretired.
    CapabilityDropped,
    /// A legacy name the base spoke is gone, unretired.
    LegacyDropped,
    /// A hard version moved and the head no longer decodes the base's value.
    VersionBroken,
    /// The manifest itself is malformed.
    Malformed,
}

impl Rule {
    pub fn label(self) -> &'static str {
        match self {
            Self::UngatedName => "ungated-name",
            Self::LegacyGrew => "legacy-grew",
            Self::ContractChanged => "contract-changed",
            Self::CapabilityDropped => "capability-dropped",
            Self::LegacyDropped => "legacy-dropped",
            Self::VersionBroken => "version-broken",
            Self::Malformed => "malformed",
        }
    }

    /// How to fix it, for the CI message.
    pub fn fix(self) -> &'static str {
        match self {
            Self::UngatedName => {
                "put it under a new capability id (`-v1`, or `-v2` of a changed one), advertise that id in the handshake, and send the name only to a peer that listed the id"
            }
            Self::LegacyGrew => "a new name is never legacy: gate it under a new capability id",
            Self::ContractChanged => {
                "an id names one contract: leave the old id's set as it was and add a new id (`-v2`) for the new set"
            }
            Self::CapabilityDropped | Self::LegacyDropped => {
                "keep serving it while old peers exist, or add it to `retired` with the reason and date"
            }
            Self::VersionBroken => {
                "keep decoding the old version (list it in `accepts`) and pick the version per peer in the handshake"
            }
            Self::Malformed => "fix the manifest's shape (see the detail)",
        }
    }
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} {}: {}: {} (fix: {})",
            self.protocol,
            self.rule.label(),
            self.subject,
            self.detail,
            self.rule.fix()
        )
    }
}

/// The base revision's manifest against the head's. `base` is `None` when the base has no
/// manifest yet (the first revision that records one): nothing to compare, so no findings.
pub fn check(base: Option<&Manifest>, head: &Manifest) -> Vec<Finding> {
    let protocol = head.protocol.clone();
    let finding = |rule, subject: &str, detail: String| Finding {
        protocol: protocol.clone(),
        rule,
        subject: subject.to_owned(),
        detail,
    };
    let mut findings: Vec<Finding> =
        head.validate().into_iter().map(|e| finding(Rule::Malformed, "manifest", e)).collect();
    let Some(base) = base else { return findings };

    let base_names = base.names();
    let new_ids: BTreeSet<&str> = head
        .capabilities
        .keys()
        .filter(|id| !base.capabilities.contains_key(*id))
        .map(String::as_str)
        .collect();

    for name in head.names() {
        if base_names.contains(name) {
            continue;
        }
        let gates = head.gates(name);
        if !gates.iter().any(|id| new_ids.contains(id)) {
            let why = if gates.is_empty() {
                "added with no capability".to_owned()
            } else {
                format!("added under {} which old peers already advertise", gates.join(", "))
            };
            findings.push(finding(Rule::UngatedName, name, why));
        }
    }
    for name in head.legacy.difference(&base.legacy) {
        findings.push(finding(
            Rule::LegacyGrew,
            name,
            "legacy names are the ones that predate gating".to_owned(),
        ));
    }
    for (id, names) in &base.capabilities {
        match head.capabilities.get(id) {
            Some(head_names) if head_names != names => {
                let added: Vec<_> = head_names.difference(names).collect();
                let removed: Vec<_> = names.difference(head_names).collect();
                findings.push(finding(
                    Rule::ContractChanged,
                    id,
                    format!("added {added:?}, removed {removed:?}"),
                ));
            }
            Some(_) => {}
            None if head.retired.contains_key(id) => {}
            None => findings.push(finding(
                Rule::CapabilityDropped,
                id,
                "old peers that rely on it lose it".to_owned(),
            )),
        }
    }
    for name in &base.legacy {
        if !head.legacy.contains(name)
            && !head.retired.contains_key(name)
            && head.gates(name).is_empty()
        {
            findings.push(finding(
                Rule::LegacyDropped,
                name,
                "old peers still send or expect it".to_owned(),
            ));
        }
    }
    for (key, base_version) in &base.versions {
        let Some(head_version) = head.versions.get(key) else {
            findings.push(finding(Rule::VersionBroken, key, "the version is gone".to_owned()));
            continue;
        };
        if head_version == base_version {
            continue;
        }
        let decodes_old = head.accepts.get(key).is_some_and(|a| a.contains(base_version));
        if !decodes_old {
            findings.push(finding(
                Rule::VersionBroken,
                key,
                format!("{base_version} -> {head_version}: an old peer's frames no longer decode"),
            ));
        }
    }
    findings
}

/// A peer that knows only an older manifest: what it advertises and what it would refuse.
#[derive(Clone, Debug)]
pub struct OldPeer {
    manifest: Manifest,
    names: BTreeSet<String>,
}

impl OldPeer {
    pub fn new(manifest: Manifest) -> Self {
        let names = manifest.names().into_iter().map(str::to_owned).collect();
        Self { manifest, names }
    }

    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// The capability ids it would advertise in the handshake.
    pub fn advertises(&self) -> Vec<&str> {
        self.manifest.capabilities.keys().map(String::as_str).collect()
    }

    /// Whether it would understand `name`.
    pub fn knows(&self, name: &str) -> bool {
        self.names.contains(name)
    }

    /// Whether it advertises `capability`.
    pub fn lists(&self, capability: &str) -> bool {
        self.manifest.capabilities.contains_key(capability)
    }
}

/// Which way a message went.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Dir {
    /// From the side under test (the new build) to its peer.
    Sent,
    /// From the peer to the side under test.
    Received,
}

/// Every wire name each side put on the wire in one run, and every name a side refused.
#[derive(Debug, Default)]
pub struct Tap {
    seen: Mutex<BTreeSet<(Dir, String)>>,
    refused: Mutex<BTreeSet<(Dir, String)>>,
}

impl Tap {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn record(&self, dir: Dir, name: impl Into<String>) {
        if let Ok(mut seen) = self.seen.lock() {
            seen.insert((dir, name.into()));
        }
    }

    /// The receiving side did not know `name` (an `unknown method`, `unknown frame type`,
    /// `unknown_service` answer, or a dropped link).
    pub fn refused(&self, dir: Dir, name: impl Into<String>) {
        if let Ok(mut refused) = self.refused.lock() {
            refused.insert((dir, name.into()));
        }
    }

    pub fn seen(&self) -> BTreeSet<(Dir, String)> {
        self.seen.lock().map(|s| s.clone()).unwrap_or_default()
    }

    /// The one-sided messages of a run between the new build (`head`) and an old peer:
    /// - a name either side put on the wire that `head` does not declare (the manifest is
    ///   incomplete, so the static check cannot see it);
    /// - a name the new side sent that the old peer does not know;
    /// - a name either side refused.
    pub fn one_sided(&self, head: &Manifest, old: &OldPeer) -> Vec<String> {
        let declared = head.names();
        let mut problems = Vec::new();
        for (dir, name) in self.seen() {
            if !declared.contains(name.as_str()) {
                problems.push(format!(
                    "{dir:?} {name}: on the wire but not in the {} manifest",
                    head.protocol
                ));
            }
            if dir == Dir::Sent && !old.knows(&name) {
                let gates = head.gates(&name);
                problems.push(format!(
                    "Sent {name} to an old peer that does not know it (gated by {gates:?}; it advertised {:?})",
                    old.advertises()
                ));
            }
        }
        if let Ok(refused) = self.refused.lock() {
            for (dir, name) in refused.iter() {
                problems.push(format!("{dir:?} {name}: refused by the receiver"));
            }
        }
        problems
    }

    /// Panics with every one-sided message, for a test.
    pub fn assert_lockstep(&self, head: &Manifest, old: &OldPeer) {
        let problems = self.one_sided(head, old);
        assert!(
            problems.is_empty(),
            "{} one-sided message(s) between the new {} and an old peer:\n  {}",
            problems.len(),
            head.protocol,
            problems.join("\n  ")
        );
    }
}

/// The base manifest for `protocol` a lockstep test runs against: `$CMUX_WIRE_BASE_DIR/<protocol>.json`
/// when CI wrote the PR base's manifests there (`wire-lockstep-check --export-base DIR`), else
/// `fallback` (the committed head manifest, which still catches undeclared names).
pub fn base_manifest(protocol: &str, fallback: &str) -> Manifest {
    if let Some(dir) = std::env::var_os("CMUX_WIRE_BASE_DIR") {
        let path = std::path::Path::new(&dir).join(format!("{protocol}.json"));
        if let Ok(text) = std::fs::read_to_string(&path)
            && let Ok(manifest) = Manifest::from_json(&text)
        {
            return manifest;
        }
    }
    Manifest::from_json(fallback).unwrap_or_else(|e| panic!("{protocol} manifest: {e}"))
}

/// Compares a protocol's generated manifest with its committed file; with
/// `CMUX_UPDATE_WIRE_MANIFEST=1` rewrites the file instead. For a protocol crate's snapshot test.
pub fn assert_manifest_current(generated: &Manifest, committed_path: &std::path::Path) {
    let errors = generated.validate();
    assert!(errors.is_empty(), "{} manifest: {}", generated.protocol, errors.join("; "));
    let fresh = generated.to_json();
    if std::env::var_os("CMUX_UPDATE_WIRE_MANIFEST").is_some() {
        std::fs::write(committed_path, &fresh)
            .unwrap_or_else(|e| panic!("write {}: {e}", committed_path.display()));
        return;
    }
    let committed = std::fs::read_to_string(committed_path).unwrap_or_default();
    assert!(
        committed == fresh,
        "{} is stale: rerun this test with CMUX_UPDATE_WIRE_MANIFEST=1 and commit it\n----- generated -----\n{fresh}",
        committed_path.display()
    );
}

#[cfg(test)]
mod tests;
