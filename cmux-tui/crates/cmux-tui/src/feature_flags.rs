//! Invite-wave flags (plans/cmux-next/tui-tester-rollout.md #10).
//!
//! The nightly publishes `notes/flags.json` beside the release notes, signed
//! (`notes/flags.json.sig`, base64 Ed25519) with the same `content-signing`
//! key, from the reviewed `release-notes/next/flags.json`:
//!
//! ```json
//! { "version": 1,
//!   "default": { "DisabledFeatures": ["cloud-vm"] },
//!   "cohorts": { "linux-wave-1": { "DisabledFeatures": ["remote-browser"] } } }
//! ```
//!
//! Each object holds policy keys in the shape of `managed/policy.rs`; a
//! cohort's keys replace the default's, except `Features`, whose names merge
//! (the cohort's state wins for a name). The `Features*` keys are the remote
//! feature overrides of `schemas/features/flags-document.md`: [`features`]
//! gives the daemon's entries, and a document whose `FeaturesSerial` is lower
//! than the cached one's is refused. The owner fetches the document at
//! start (`owner_start/background_checks.rs`) and caches it at the state root
//! only when the signature verifies; every reader verifies the cache again,
//! so an edited file on disk counts for nothing. A tester's cohort comes from
//! `CMUX_TUI_COHORT` or the `tester.cohort` key of cmux.json, else `default`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use base64::Engine;
use serde_json::Value;

/// The `content-signing` public key (raw, base64), as `ContentSignature.publicKey` in the app.
const PUBLIC_KEY: &str = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4=";
/// Where the nightly publishes the document.
pub(crate) const FLAGS_URL: &str = "https://files-next.cmux.com/nightly-next/next/notes/flags.json";
const CACHE_NAME: &str = "flags.json";
const DEFAULT_COHORT: &str = "default";
#[cfg(debug_assertions)]
pub(crate) const TEST_URL_ENV: &str = "CMUX_TUI_TEST_FLAGS_URL";
#[cfg(debug_assertions)]
const TEST_PUBLIC_KEY_ENV: &str = "CMUX_TUI_TEST_CONTENT_PUBLIC_KEY";

/// Whether `signature` (base64 text) is an Ed25519 signature of `data` by `public_key` (raw, base64).
pub(crate) fn verify(data: &[u8], signature: &[u8], public_key: &str) -> bool {
    let engine = &base64::engine::general_purpose::STANDARD;
    let Ok(signature) = engine.decode(String::from_utf8_lossy(signature).trim()) else {
        return false;
    };
    let Ok(key) = engine.decode(public_key) else { return false };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
        .verify(data, &signature)
        .is_ok()
}

/// The policy keys `document` sets for `cohort`: the default's, replaced by the cohort's.
/// None when the document is not version 1.
pub(crate) fn resolve(document: &Value, cohort: &str) -> Option<BTreeMap<String, Value>> {
    if document.get("version").and_then(Value::as_u64) != Some(1) {
        return None;
    }
    let mut keys = BTreeMap::new();
    let objects =
        [document.get("default"), document.get("cohorts").and_then(|cohorts| cohorts.get(cohort))];
    for object in objects.into_iter().flatten().filter_map(Value::as_object) {
        for (key, value) in object {
            if let (Some(Value::Object(merged)), Value::Object(more)) = (keys.get_mut(key), value)
                && key == FEATURES
            {
                merged.extend(more.iter().map(|(name, state)| (name.clone(), state.clone())));
            } else {
                keys.insert(key.clone(), value.clone());
            }
        }
    }
    Some(keys)
}

/// `DisabledFeatures` of resolved keys.
pub(crate) fn disabled_features(keys: &BTreeMap<String, Value>) -> Vec<String> {
    keys.get("DisabledFeatures")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(|item| item.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

/// What the `Features*` keys are checked against: this build and the time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct FeaturesContext {
    /// The build number (`CFBundleVersion`, the nightly's `NIGHTLY_BUILD`); None when unknown.
    pub build: Option<u64>,
    /// Unix seconds now.
    pub now: u64,
}

/// The remote feature overrides one cohort resolved to.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RemoteFeatures {
    /// `FeaturesSerial`, when set.
    pub serial: Option<u64>,
    /// Each named feature and whether the document turns it on.
    pub states: BTreeMap<String, bool>,
}

/// Why a cohort's `Features` do not apply. The document's other keys still do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum FeaturesRejected {
    /// A `Features*` key has the wrong type, or a state is not `"on"` or `"off"`.
    Malformed(&'static str),
    /// `FeaturesExpiresAt` is not after now.
    Expired {
        expires_at: u64,
    },
    /// A build range is set and this build's number is unknown.
    BuildUnknown,
    BuildBelowMin {
        build: u64,
        min: u64,
    },
    BuildAboveMax {
        build: u64,
        max: u64,
    },
}

impl FeaturesRejected {
    /// The reason as `schemas/features/flags-vectors.json` names it.
    #[cfg_attr(not(test), expect(dead_code, reason = "the vectors name reasons; logs use Display"))]
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::Malformed(_) => "malformed",
            Self::Expired { .. } => "expired",
            Self::BuildUnknown => "buildUnknown",
            Self::BuildBelowMin { .. } => "buildBelowMin",
            Self::BuildAboveMax { .. } => "buildAboveMax",
        }
    }
}

impl std::fmt::Display for FeaturesRejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Malformed(key) => write!(f, "{key} is malformed"),
            Self::Expired { expires_at } => write!(f, "Features expired at {expires_at}"),
            Self::BuildUnknown => f.write_str("this build's number is unknown"),
            Self::BuildBelowMin { build, min } => {
                write!(f, "build {build} < FeaturesMinBuild {min}")
            }
            Self::BuildAboveMax { build, max } => {
                write!(f, "build {build} > FeaturesMaxBuild {max}")
            }
        }
    }
}

const FEATURES: &str = "Features";
const FEATURES_SERIAL: &str = "FeaturesSerial";
const FEATURES_EXPIRES_AT: &str = "FeaturesExpiresAt";
const FEATURES_MIN_BUILD: &str = "FeaturesMinBuild";
const FEATURES_MAX_BUILD: &str = "FeaturesMaxBuild";

/// The `Features*` keys of resolved keys, checked against `context`. Every
/// name is kept, the app's too; [`features`] keeps the daemon's. A malformed
/// key rejects them all, as Chromium drops a seed that does not parse instead
/// of applying part of it (`components/variations/variations_seed_store.cc`).
pub(crate) fn remote_features(
    keys: &BTreeMap<String, Value>,
    context: FeaturesContext,
) -> Result<RemoteFeatures, FeaturesRejected> {
    let number = |key: &'static str| match keys.get(key) {
        None => Ok(None),
        Some(value) => value.as_u64().map(Some).ok_or(FeaturesRejected::Malformed(key)),
    };
    let serial = number(FEATURES_SERIAL)?;
    let expires_at = number(FEATURES_EXPIRES_AT)?;
    let min = number(FEATURES_MIN_BUILD)?;
    let max = number(FEATURES_MAX_BUILD)?;
    let mut states = BTreeMap::new();
    if let Some(features) = keys.get(FEATURES) {
        let features = features.as_object().ok_or(FeaturesRejected::Malformed(FEATURES))?;
        for (name, state) in features {
            let on = match state.as_str() {
                Some("on") => true,
                Some("off") => false,
                _ => return Err(FeaturesRejected::Malformed(FEATURES)),
            };
            states.insert(name.clone(), on);
        }
    }
    if let Some(expires_at) = expires_at.filter(|&expires_at| context.now >= expires_at) {
        return Err(FeaturesRejected::Expired { expires_at });
    }
    if min.is_some() || max.is_some() {
        let build = context.build.ok_or(FeaturesRejected::BuildUnknown)?;
        if let Some(min) = min.filter(|&min| build < min) {
            return Err(FeaturesRejected::BuildBelowMin { build, min });
        }
        if let Some(max) = max.filter(|&max| build > max) {
            return Err(FeaturesRejected::BuildAboveMax { build, max });
        }
    }
    Ok(RemoteFeatures { serial, states })
}

/// The remote overrides of the daemon's features (registry `process` `daemon`
/// or `both`, the `cmux-features` table), in table order. Names of app-only
/// features are left out, not refused: one document serves both processes.
#[cfg_attr(
    not(test),
    expect(dead_code, reason = "the daemon's first remote-overridable feature reads this")
)]
pub(crate) fn features(
    keys: &BTreeMap<String, Value>,
    context: FeaturesContext,
) -> Result<Vec<(&'static str, bool)>, FeaturesRejected> {
    let remote = remote_features(keys, context)?;
    let table = cmux_features::Snapshot::defaults(cmux_features::Channel::Release);
    Ok(table
        .iter()
        .filter_map(|(def, _, _)| remote.states.get(def.name).map(|&on| (def.name, on)))
        .collect())
}

/// Err when `next` lowers the `FeaturesSerial` that `previous` gave a cohort:
/// the default, and each cohort both documents name. A replayed older document
/// verifies, so this is what keeps it from undoing a kill switch.
fn refuse_older_serial(previous: &Value, next: &Value) -> Result<(), String> {
    let serial = |document: &Value, cohort: &str| {
        resolve(document, cohort)
            .and_then(|keys| keys.get(FEATURES_SERIAL).and_then(Value::as_u64))
            .unwrap_or(0)
    };
    let cohorts = |document: &Value| -> Vec<String> {
        let names = document.get("cohorts").and_then(Value::as_object);
        names.into_iter().flat_map(|cohorts| cohorts.keys().cloned()).collect()
    };
    let previous_cohorts = cohorts(previous);
    let shared = cohorts(next).into_iter().filter(|name| previous_cohorts.contains(name));
    for cohort in std::iter::once(DEFAULT_COHORT.to_string()).chain(shared) {
        let (old, new) = (serial(previous, &cohort), serial(next, &cohort));
        if new < old {
            return Err(format!("older FeaturesSerial for cohort {cohort}: {new} < {old}"));
        }
    }
    Ok(())
}

/// The public key this build trusts.
pub(crate) fn public_key() -> String {
    #[cfg(debug_assertions)]
    if let Some(key) = std::env::var(TEST_PUBLIC_KEY_ENV).ok().filter(|key| !key.is_empty()) {
        return key;
    }
    PUBLIC_KEY.to_string()
}

/// The state root (`owner-panics-*.jsonl`, the caches) for this process.
pub(crate) fn state_root() -> Option<PathBuf> {
    let sessions = cmux_tui_core::platform::workspace_state_dir()?;
    Some(sessions.parent().map(PathBuf::from).unwrap_or(sessions))
}

fn cache_paths(root: &Path) -> (PathBuf, PathBuf) {
    (root.join(CACHE_NAME), root.join(format!("{CACHE_NAME}.sig")))
}

/// Caches a fetched document when its signature verifies. Err names why not.
pub(crate) fn store(root: &Path, data: &[u8], signature: &[u8], key: &str) -> Result<(), String> {
    if !verify(data, signature, key) {
        return Err("bad signature".into());
    }
    let document: Value =
        serde_json::from_slice(data).map_err(|error| format!("not JSON: {error}"))?;
    if resolve(&document, DEFAULT_COHORT).is_none() {
        return Err("not a version 1 document".into());
    }
    if let Some(previous) = cached(root, key) {
        refuse_older_serial(&previous, &document)?;
    }
    let (data_path, signature_path) = cache_paths(root);
    // The signature first: a crash between the two leaves a pair that fails
    // verification, never an old signature that vouches for nothing new.
    write_atomic(&signature_path, signature)?;
    write_atomic(&data_path, data)
}

/// The cached document, when its signature verifies.
pub(crate) fn cached(root: &Path, key: &str) -> Option<Value> {
    let (data_path, signature_path) = cache_paths(root);
    let data = std::fs::read(data_path).ok()?;
    let signature = std::fs::read(signature_path).ok()?;
    if !verify(&data, &signature, key) {
        return None;
    }
    serde_json::from_slice(&data).ok()
}

/// This tester's cohort: `CMUX_TUI_COHORT`, else cmux.json `tester.cohort`, else `default`.
pub(crate) fn cohort(env: &dyn Fn(&str) -> Option<String>, settings: Option<&Value>) -> String {
    env("CMUX_TUI_COHORT")
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            settings
                .and_then(|root| cmux_config::value::value_at(root, &["tester", "cohort"][..]))
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .map(String::from)
        })
        .map(|value| value.trim().to_string())
        .unwrap_or_else(|| DEFAULT_COHORT.to_string())
}

/// cmux.json as JSON, when it parses.
pub(crate) fn settings() -> Option<Value> {
    std::fs::read_to_string(cmux_config::config_path())
        .ok()
        .and_then(|text| cmux_config::jsonc::parse(&text).ok())
}

/// The cohort and what the cached, verified document turns off for it.
pub(crate) fn report() -> (String, Vec<String>) {
    let env = |name: &str| std::env::var(name).ok();
    let cohort = cohort(&env, settings().as_ref());
    let disabled = state_root()
        .and_then(|root| cached(&root, &public_key()))
        .and_then(|document| resolve(&document, &cohort))
        .map(|keys| disabled_features(&keys))
        .unwrap_or_default();
    (cohort, disabled)
}

/// What the managed policy and this tester's wave turn off.
fn disabled_now() -> Vec<String> {
    let env = |name: &str| std::env::var(name).ok();
    let managed = cmux_config::managed::default_reader(env).read();
    let mut disabled = managed
        .forced
        .get("DisabledFeatures")
        .map(|value| {
            disabled_features(&BTreeMap::from([("DisabledFeatures".into(), value.clone())]))
        })
        .unwrap_or_default();
    disabled.extend(report().1);
    disabled
}

/// The daemon's features, resolved once at start (p12-perf-process 3.9):
/// the channel default, then `CMUX_ENABLE_FEATURES` / `CMUX_DISABLE_FEATURES`,
/// then `DisabledFeatures` of the managed policy and the signed document,
/// which win (Chromium's `FeatureList` with its policy overrides).
pub(crate) fn daemon_features() -> cmux_features::Snapshot {
    let env = |name: &str| std::env::var(name).ok();
    let exe = std::env::current_exe().ok();
    let kind = crate::app_identity::AppIdentity::detect(env, exe.as_deref())
        .map(|identity| identity.build().kind());
    let enable = env(cmux_features::ENABLE_ENV);
    let disable = env(cmux_features::DISABLE_ENV);
    cmux_features::Snapshot::from_env(channel(kind), enable.as_deref(), disable.as_deref())
        .with_disabled(disabled_now().iter().map(String::as_str))
}

/// The registry channel of a build: NIGHTLY's own, RC and release builds
/// release's, DEV and staging dev's. A process outside any app bundle is a
/// release when built optimized (an npm or PyPI cmux-tui), else dev.
fn channel(
    kind: Option<cmux_agent_pane_policy::build_identity::BuildKind>,
) -> cmux_features::Channel {
    use cmux_agent_pane_policy::build_identity::BuildKind;
    use cmux_features::Channel;
    match kind.unwrap_or(BuildKind::Unbundled) {
        BuildKind::Nightly => Channel::Nightly,
        BuildKind::Release | BuildKind::Rc => Channel::Release,
        BuildKind::Dev | BuildKind::Staging => Channel::Dev,
        BuildKind::Unbundled if cfg!(debug_assertions) => Channel::Dev,
        BuildKind::Unbundled => Channel::Release,
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut temp_name = path.file_name().unwrap_or_default().to_os_string();
    temp_name.push(".tmp");
    let temp = path.with_file_name(temp_name);
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file =
        options.open(&temp).map_err(|error| format!("write {}: {error}", temp.display()))?;
    file.write_all(bytes).map_err(|error| format!("write {}: {error}", temp.display()))?;
    std::fs::rename(&temp, path).map_err(|error| format!("write {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    fn key_pair() -> Ed25519KeyPair {
        Ed25519KeyPair::from_seed_unchecked(&[3u8; 32]).unwrap()
    }

    fn encode(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn only_the_key_holder_signs_a_document() {
        let pair = key_pair();
        let key = encode(pair.public_key().as_ref());
        let data = br#"{"version":1}"#;
        let signature = format!("{}\n", encode(pair.sign(data).as_ref()));
        assert!(verify(data, signature.as_bytes(), &key));
        assert!(!verify(br#"{"version":2}"#, signature.as_bytes(), &key));
        assert!(!verify(data, signature.as_bytes(), PUBLIC_KEY));
        assert!(!verify(data, b"not base64!", &key));
    }

    #[test]
    fn a_cohort_replaces_the_default_keys() {
        let document = serde_json::json!({
            "version": 1,
            "default": {"DisabledFeatures": ["a"], "MinimumVersion": "1.0.0"},
            "cohorts": {"wave-1": {"DisabledFeatures": ["b"]}},
        });
        let wave = resolve(&document, "wave-1").unwrap();
        assert_eq!(disabled_features(&wave), ["b"]);
        assert_eq!(wave["MinimumVersion"], "1.0.0");
        assert_eq!(disabled_features(&resolve(&document, "other").unwrap()), ["a"]);
        assert!(resolve(&serde_json::json!({"version": 2}), "wave-1").is_none());
    }

    #[test]
    fn the_cohort_comes_from_the_environment_then_the_settings() {
        let settings = serde_json::json!({"tester": {"cohort": "mac-wave-2"}});
        let none = |_: &str| -> Option<String> { None };
        let set = |name: &str| (name == "CMUX_TUI_COHORT").then(|| "linux-wave-1".to_string());
        assert_eq!(cohort(&set, Some(&settings)), "linux-wave-1");
        assert_eq!(cohort(&none, Some(&settings)), "mac-wave-2");
        assert_eq!(cohort(&none, None), "default");
    }

    #[test]
    fn only_a_verified_document_is_cached() {
        let root = tempfile::tempdir().unwrap();
        let pair = key_pair();
        let key = encode(pair.public_key().as_ref());
        let data = br#"{"version":1,"default":{"DisabledFeatures":["x"]}}"#;
        let signature = encode(pair.sign(data).as_ref());
        assert!(store(root.path(), b"{}", signature.as_bytes(), &key).is_err());
        assert!(cached(root.path(), &key).is_none());
        store(root.path(), data, signature.as_bytes(), &key).unwrap();
        assert!(cached(root.path(), &key).is_some());
        // An edit on disk voids the cache.
        std::fs::write(root.path().join(CACHE_NAME), br#"{"version":1}"#).unwrap();
        assert!(cached(root.path(), &key).is_none());
    }

    #[test]
    fn each_build_kind_reads_its_channel_default() {
        use cmux_agent_pane_policy::build_identity::BuildKind;
        use cmux_features::Channel;
        assert_eq!(channel(Some(BuildKind::Nightly)), Channel::Nightly);
        assert_eq!(channel(Some(BuildKind::Release)), Channel::Release);
        assert_eq!(channel(Some(BuildKind::Rc)), Channel::Release);
        assert_eq!(channel(Some(BuildKind::Dev)), Channel::Dev);
        assert_eq!(channel(Some(BuildKind::Staging)), Channel::Dev);
        // Tests build unoptimized: an unbundled test binary is a dev build.
        assert_eq!(channel(None), Channel::Dev);
    }

    /// The vectors the app's `ContentSignature` and remote overrides replay too.
    fn vectors() -> Value {
        serde_json::from_str(include_str!("../../../../schemas/features/flags-vectors.json"))
            .unwrap()
    }

    #[test]
    fn the_shared_signature_vectors_verify_as_in_the_app() {
        let vectors = vectors();
        let key = vectors["public_key"].as_str().unwrap();
        let cases = vectors["signature"].as_array().unwrap();
        assert!(cases.iter().any(|case| case["valid"] == true));
        assert!(cases.iter().any(|case| case["valid"] == false));
        for case in cases {
            let data = case["data"].as_str().unwrap().as_bytes();
            let signature = case["signature"].as_str().unwrap().as_bytes();
            let valid = case["valid"].as_bool().unwrap();
            assert_eq!(verify(data, signature, key), valid, "{}", case["name"]);
        }
    }

    #[test]
    fn the_shared_resolve_vectors_give_each_cohort_its_features() {
        for case in vectors()["resolve"].as_array().unwrap() {
            let name = &case["name"];
            let keys = resolve(&case["document"], case["cohort"].as_str().unwrap()).unwrap();
            let context = FeaturesContext {
                build: case["build"].as_u64(),
                now: case["now"].as_u64().unwrap(),
            };
            let result = remote_features(&keys, context);
            if let Some(reason) = case.get("rejected") {
                assert_eq!(result.map_err(|why| why.code()).err(), reason.as_str(), "{name}");
                continue;
            }
            let remote = result.unwrap_or_else(|why| panic!("{name}: {why}"));
            let expected: BTreeMap<String, bool> =
                serde_json::from_value(case["features"].clone()).unwrap();
            assert_eq!(remote.states, expected, "{name}");
            assert_eq!(remote.serial, case.get("serial").and_then(Value::as_u64), "{name}");
        }
    }

    #[test]
    fn the_published_document_passes_the_nightly_check_and_resolves() {
        let document: Value =
            serde_json::from_str(include_str!("../../../../release-notes/next/flags.json"))
                .unwrap();
        assert_eq!(document["version"], 1, "nightly.yml asserts version == 1");
        assert!(document.get("default").is_none_or(Value::is_object));
        assert!(document.get("cohorts").is_none_or(Value::is_object));
        let keys = resolve(&document, DEFAULT_COHORT).unwrap();
        let context = FeaturesContext { build: None, now: 0 };
        let remote = remote_features(&keys, context).unwrap();
        assert!(remote.serial.is_some(), "every publish sets FeaturesSerial");
        assert!(features(&keys, context).is_ok());
    }

    #[test]
    fn the_daemon_takes_only_its_own_features() {
        let keys = BTreeMap::from([(
            FEATURES.to_string(),
            serde_json::json!({"noSuchDaemonFeature": "off", "cefLayerHosting": "on"}),
        )]);
        let context = FeaturesContext { build: Some(1), now: 0 };
        assert_eq!(remote_features(&keys, context).unwrap().states.len(), 2);
        let daemon: Vec<&str> = cmux_features::Snapshot::defaults(cmux_features::Channel::Release)
            .iter()
            .map(|(def, _, _)| def.name)
            .collect();
        let taken = features(&keys, context).unwrap();
        assert!(taken.iter().all(|(name, _)| daemon.contains(name)), "{taken:?}");
        assert!(!taken.iter().any(|(name, _)| *name == "noSuchDaemonFeature"));
    }

    #[test]
    fn an_older_serial_never_replaces_the_cache() {
        let root = tempfile::tempdir().unwrap();
        let pair = key_pair();
        let key = encode(pair.public_key().as_ref());
        let put = |document: Value| {
            let data = serde_json::to_vec(&document).unwrap();
            store(root.path(), &data, encode(pair.sign(&data).as_ref()).as_bytes(), &key)
        };
        let wave = |serial: u64| {
            serde_json::json!({
                "version": 1,
                "default": {"FeaturesSerial": 5, "Features": {"x": "off"}},
                "cohorts": {"wave": {"FeaturesSerial": serial}},
            })
        };
        // A document from before FeaturesSerial counts as serial 0.
        put(serde_json::json!({"version": 1, "default": {"DisabledFeatures": ["a"]}})).unwrap();
        put(wave(9)).unwrap();
        put(wave(9)).unwrap();
        let older = put(wave(8)).unwrap_err();
        assert!(older.contains("cohort wave: 8 < 9"), "{older}");
        let replayed = put(serde_json::json!({"version": 1, "default": {}})).unwrap_err();
        assert!(replayed.contains("cohort default: 0 < 5"), "{replayed}");
        // A cohort the new document drops is not compared; its testers get the default.
        put(serde_json::json!({"version": 1, "default": {"FeaturesSerial": 6}})).unwrap();
        assert_eq!(cached(root.path(), &key).unwrap()["default"]["FeaturesSerial"], 6);
    }

    #[test]
    fn a_cohort_merges_feature_names_and_replaces_other_keys() {
        let document = serde_json::json!({
            "version": 1,
            "default": {"Features": {"a": "off", "b": "off"}, "FeaturesSerial": 2},
            "cohorts": {"wave": {"Features": {"b": "on"}, "FeaturesSerial": 3}},
        });
        let keys = resolve(&document, "wave").unwrap();
        assert_eq!(keys[FEATURES], serde_json::json!({"a": "off", "b": "on"}));
        assert_eq!(keys[FEATURES_SERIAL], 3);
        // A cohort's Features that is not an object replaces the default's, and is malformed.
        let broken = serde_json::json!({
            "version": 1,
            "default": {"Features": {"a": "off"}},
            "cohorts": {"wave": {"Features": ["a"]}},
        });
        let keys = resolve(&broken, "wave").unwrap();
        let context = FeaturesContext { build: None, now: 0 };
        assert_eq!(remote_features(&keys, context), Err(FeaturesRejected::Malformed(FEATURES)));
    }
}
