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
//! cohort's keys replace the default's. The `Features*` keys are the remote
//! feature overrides of `schemas/features/flags-document.md`, read per layer
//! by [`remote_features`] ([`features`] gives the daemon's entries), and a
//! document whose serial (its highest `FeaturesSerial`) is lower than the
//! cached one's is refused. The owner fetches the document at
//! start (`owner_start/background_checks.rs`) and caches it at the state root
//! only when the signature verifies; every reader verifies the cache again,
//! so an edited file on disk counts for nothing. A tester's cohort comes from
//! `CMUX_TUI_COHORT` or the `tester.cohort` key of cmux.json, else `default`.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{Map, Value};

// The reading half, shared with the acpmux daemon so one feature resolves the
// same in both (cmux-features `sources`).
#[cfg(test)]
use cmux_features::sources::{CACHE_NAME, PUBLIC_KEY, cohort, disabled_features};
pub(crate) use cmux_features::sources::{
    DEFAULT_COHORT, FEATURES, FEATURES_EXPIRES_AT, FEATURES_MAX_BUILD, FEATURES_MIN_BUILD,
    FEATURES_SERIAL, Layer, cache_paths, cached, layers, public_key, report, resolve, settings,
    state_root, verify,
};

/// Where the nightly publishes the document.
pub(crate) const FLAGS_URL: &str = "https://files-next.cmux.com/nightly-next/next/notes/flags.json";
#[cfg(debug_assertions)]
pub(crate) const TEST_URL_ENV: &str = "CMUX_TUI_TEST_FLAGS_URL";

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
    /// The document's serial ([`document_serial`]), when any layer sets one.
    pub serial: Option<u64>,
    /// Each named feature and whether the document turns it on: the default
    /// layer's, then the cohort layer's (its state wins for a name), each only
    /// when its own gates pass.
    pub states: BTreeMap<String, bool>,
    /// The layers whose `Features` do not apply, and why.
    pub rejected: Vec<(Layer, FeaturesRejected)>,
}

/// Why one layer's `Features` do not apply. The document's other keys, and
/// the other layer's `Features`, still do.
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

/// The `Features` of `document` for `cohort`, checked against `context`. The
/// default layer and the cohort layer are each checked against their own
/// `Features*` keys, as Chromium filters each study on its own
/// (`components/variations/study_filtering.cc`): a layer that fails adds
/// nothing, and the other still applies. Every name is kept, the app's too;
/// [`features`] keeps the daemon's. None when the document is not version 1.
#[cfg_attr(
    not(test),
    expect(dead_code, reason = "the daemon's first remote-overridable feature reads this")
)]
pub(crate) fn remote_features(
    document: &Value,
    cohort: &str,
    context: FeaturesContext,
) -> Option<RemoteFeatures> {
    let mut remote = RemoteFeatures { serial: document_serial(document), ..Default::default() };
    for (layer, object) in layers(document, cohort)? {
        match layer_features(object, context) {
            Ok(states) => remote.states.extend(states),
            Err(why) => remote.rejected.push((layer, why)),
        }
    }
    Some(remote)
}

/// One layer's `Features`, checked against its own `Features*` keys. A
/// malformed key rejects all of the layer's `Features`, as Chromium drops a
/// seed that does not parse instead of applying part of it
/// (`components/variations/variations_seed_store.cc`).
fn layer_features(
    keys: &Map<String, Value>,
    context: FeaturesContext,
) -> Result<BTreeMap<String, bool>, FeaturesRejected> {
    let number = |key: &'static str| match keys.get(key) {
        None => Ok(None),
        Some(value) => value.as_u64().map(Some).ok_or(FeaturesRejected::Malformed(key)),
    };
    number(FEATURES_SERIAL)?;
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
    Ok(states)
}

/// The document's serial: the highest integer `FeaturesSerial` of its
/// default and of every cohort. One number covers the whole document, as a
/// Chromium seed has one `serial_number`
/// (`components/variations/proto/variations_seed.proto`).
pub(crate) fn document_serial(document: &Value) -> Option<u64> {
    let cohorts = document.get("cohorts").and_then(Value::as_object);
    let layers = cohorts.into_iter().flat_map(|cohorts| cohorts.values());
    std::iter::once(document.get(DEFAULT_COHORT))
        .flatten()
        .chain(layers)
        .filter_map(|layer| layer.get(FEATURES_SERIAL).and_then(Value::as_u64))
        .max()
}

/// The remote overrides of the daemon's features (registry `process` `daemon`
/// or `both`, the `cmux-features` table), in table order. Names of app-only
/// features are left out, not refused: one document serves both processes.
#[cfg_attr(
    not(test),
    expect(dead_code, reason = "the daemon's first remote-overridable feature reads this")
)]
pub(crate) fn features(remote: &RemoteFeatures) -> Vec<(&'static str, bool)> {
    let table = cmux_features::Snapshot::defaults(cmux_features::Channel::Release);
    table
        .iter()
        .filter_map(|(def, _, _)| remote.states.get(def.name).map(|&on| (def.name, on)))
        .collect()
}

/// Err when `next`'s serial ([`document_serial`]) is lower than `previous`'s.
/// A replayed older document verifies, so this is what keeps it from undoing
/// a kill switch, for every cohort at once: the serial covers the whole
/// document, the cohorts `next` drops too. No `FeaturesSerial` is serial 0.
fn refuse_older_serial(previous: &Value, next: &Value) -> Result<(), String> {
    let old = document_serial(previous).unwrap_or(0);
    let new = document_serial(next).unwrap_or(0);
    if new < old {
        return Err(format!("older FeaturesSerial: {new} < {old}"));
    }
    Ok(())
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

/// [`daemon_features`], installed where core reads a feature process-wide:
/// call once at daemon start, before the mux and its first terminal.
pub(crate) fn install_daemon_features() -> cmux_features::Snapshot {
    let features = daemon_features();
    #[cfg(unix)]
    cmux_tui_core::install_terminal_holder(&features);
    features
}

/// The daemon's features, resolved once at start (p12-perf-process 3.9): the
/// shared rule (`cmux_features::sources::daemon_snapshot`, acpmux's too) on the
/// channel of the app this owner belongs to.
pub(crate) fn daemon_features() -> cmux_features::Snapshot {
    #[cfg(unix)]
    let kind = {
        let env = |name: &str| std::env::var(name).ok();
        let exe = std::env::current_exe().ok();
        crate::app_identity::AppIdentity::detect(env, exe.as_deref())
            .map(|identity| identity.build().kind())
    };
    // app_identity is unix-only: no app channel to read elsewhere.
    #[cfg(not(unix))]
    let kind = None;
    cmux_features::sources::daemon_snapshot(kind)
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
    let mut file = crate::blocking::fs::open_with(&options, &temp)
        .map_err(|error| format!("write {}: {error}", temp.display()))?;
    file.write_all(bytes).map_err(|error| format!("write {}: {error}", temp.display()))?;
    cmux_blocking::fs::rename(&temp, path)
        .map_err(|error| format!("write {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
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

    /// The shared vector: scripts/features/publish-flags.py signs it with the perf
    /// lab's committed test key (schemas/features/bench-test-signing-key.json)
    /// through openssl; the app's FeatureRemoteTests verify the same bytes.
    #[test]
    fn the_publish_tools_vector_verifies_with_the_bench_key() {
        const BENCH_TEST_PUBLIC_KEY: &str = "tOVR4m5KjnfoL+4rA/GqbLNDSgK8cJV8G0noc8Atvww=";
        const VECTOR_DOCUMENT: &str =
            r#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1}}"#;
        const VECTOR_SIGNATURE: &str = "awi7tNpxH9yQKKOTIR0rnhqC9NTbcMynkyHu64U9D1th0EHUG131NFw6LDGVN7gA+hhBDgJJA3xWZUMOv5eDBw==";
        let signature = format!("{VECTOR_SIGNATURE}\n");
        assert!(verify(VECTOR_DOCUMENT.as_bytes(), signature.as_bytes(), BENCH_TEST_PUBLIC_KEY));
        let tampered = format!("{VECTOR_DOCUMENT} ");
        assert!(!verify(tampered.as_bytes(), signature.as_bytes(), BENCH_TEST_PUBLIC_KEY));
        // The daemon trusts only the content-signing key: the test key's signature is refused there.
        assert!(!verify(VECTOR_DOCUMENT.as_bytes(), signature.as_bytes(), PUBLIC_KEY));
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
            let context = FeaturesContext {
                build: case["build"].as_u64(),
                now: case["now"].as_u64().unwrap(),
            };
            let cohort = case["cohort"].as_str().unwrap();
            let remote = remote_features(&case["document"], cohort, context).unwrap();
            let expected: BTreeMap<String, bool> =
                serde_json::from_value(case["features"].clone()).unwrap();
            assert_eq!(remote.states, expected, "{name}");
            assert_eq!(remote.serial, case.get("serial").and_then(Value::as_u64), "{name}");
            let rejected: Vec<Value> = remote
                .rejected
                .iter()
                .map(
                    |(layer, why)| serde_json::json!({"layer": layer.code(), "reason": why.code()}),
                )
                .collect();
            assert_eq!(Value::Array(rejected), case["rejected"], "{name}");
        }
    }

    #[test]
    fn the_shared_serial_vectors_refuse_every_older_document() {
        let cases = vectors()["serial"].as_array().unwrap().clone();
        assert!(cases.iter().any(|case| case["refused"] == true));
        for case in cases {
            let refused = refuse_older_serial(&case["cached"], &case["next"]).is_err();
            assert_eq!(refused, case["refused"].as_bool().unwrap(), "{}", case["name"]);
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
        assert!(resolve(&document, DEFAULT_COHORT).is_some());
        let context = FeaturesContext { build: None, now: 0 };
        let remote = remote_features(&document, DEFAULT_COHORT, context).unwrap();
        assert!(remote.serial.is_some(), "every publish sets FeaturesSerial");
        assert_eq!(remote.rejected, [], "the published Features apply");
    }

    #[test]
    fn the_daemon_takes_only_its_own_features() {
        let document = serde_json::json!({
            "version": 1,
            "default": {"Features": {"noSuchDaemonFeature": "off", "cefLayerHosting": "on"}},
        });
        let context = FeaturesContext { build: Some(1), now: 0 };
        let remote = remote_features(&document, DEFAULT_COHORT, context).unwrap();
        assert_eq!(remote.states.len(), 2);
        let daemon: Vec<&str> = cmux_features::Snapshot::defaults(cmux_features::Channel::Release)
            .iter()
            .map(|(def, _, _)| def.name)
            .collect();
        let taken = features(&remote);
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
                "default": {"FeaturesSerial": 5},
                "cohorts": {"wave": {"FeaturesSerial": serial, "Features": {"x": "off"}}},
            })
        };
        // A document from before FeaturesSerial counts as serial 0.
        put(serde_json::json!({"version": 1, "default": {"DisabledFeatures": ["a"]}})).unwrap();
        put(wave(9)).unwrap();
        put(wave(9)).unwrap();
        let older = put(wave(8)).unwrap_err();
        assert!(older.contains("older FeaturesSerial: 8 < 9"), "{older}");
        // A replay that drops the cohort holding the kill switch is older too.
        let dropped = serde_json::json!({"version": 1, "default": {"FeaturesSerial": 5}});
        let replayed = put(dropped).unwrap_err();
        assert!(replayed.contains("older FeaturesSerial: 5 < 9"), "{replayed}");
        let cached_wave = &cached(root.path(), &key).unwrap()["cohorts"]["wave"];
        assert_eq!(cached_wave["Features"]["x"], "off", "the kill switch stays cached");
        // A newer document may drop the cohort.
        put(serde_json::json!({"version": 1, "default": {"FeaturesSerial": 10}})).unwrap();
        assert_eq!(cached(root.path(), &key).unwrap()["default"]["FeaturesSerial"], 10);
    }

    #[test]
    fn each_layer_is_gated_on_its_own_and_the_cohort_wins_per_name() {
        let context = FeaturesContext { build: Some(4199), now: 0 };
        let document = serde_json::json!({
            "version": 1,
            "default": {"Features": {"a": "off", "b": "off"}, "FeaturesSerial": 2},
            "cohorts": {"wave": {"Features": {"b": "on"}, "FeaturesSerial": 3, "MinimumVersion": "2"}},
        });
        let remote = remote_features(&document, "wave", context).unwrap();
        assert_eq!(remote.states, BTreeMap::from([("a".into(), false), ("b".into(), true)]));
        assert_eq!(remote.serial, Some(3));
        // resolve gives the policy keys only, so no Features* key crosses layers.
        let keys = resolve(&document, "wave").unwrap();
        assert_eq!(keys, BTreeMap::from([("MinimumVersion".into(), Value::from("2"))]));
        // A cohort out of range keeps the default's kill switches.
        let gated = serde_json::json!({
            "version": 1,
            "default": {"Features": {"a": "off"}},
            "cohorts": {"wave": {"Features": {"a": "on"}, "FeaturesMinBuild": 4200}},
        });
        let remote = remote_features(&gated, "wave", context).unwrap();
        assert_eq!(remote.states, BTreeMap::from([("a".into(), false)]));
        let below = FeaturesRejected::BuildBelowMin { build: 4199, min: 4200 };
        assert_eq!(remote.rejected, [(Layer::Cohort, below)]);
        // A cohort's Features that is not an object is malformed; the default's still apply.
        let broken = serde_json::json!({
            "version": 1,
            "default": {"Features": {"a": "off"}},
            "cohorts": {"wave": {"Features": ["a"]}},
        });
        let remote = remote_features(&broken, "wave", context).unwrap();
        assert_eq!(remote.states, BTreeMap::from([("a".into(), false)]));
        assert_eq!(remote.rejected, [(Layer::Cohort, FeaturesRejected::Malformed(FEATURES))]);
    }
}
