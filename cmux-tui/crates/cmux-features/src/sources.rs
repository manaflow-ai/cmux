//! Where a daemon's feature values come from (p12-perf-process 3.9), for the
//! cmux-tui owner and the acpmux daemon alike, so one feature resolves the
//! same in both: the registry default of this build's channel, then
//! [`ENABLE_ENV`](crate::ENABLE_ENV) / [`DISABLE_ENV`](crate::DISABLE_ENV),
//! then `DisabledFeatures` of the managed policy and of the signed invite-wave
//! document, which win (Chromium's `FeatureList` with its policy overrides,
//! `base/feature_list.cc`).
//!
//! The document is the nightly's `notes/flags.json`, signed (base64 Ed25519)
//! with the `content-signing` key. The cmux-tui owner fetches it and caches it
//! at the state root only when the signature verifies
//! (`cmux-tui/src/feature_flags.rs`); every reader here verifies the cache
//! again, so an edited file on disk counts for nothing. A tester's cohort
//! comes from `CMUX_TUI_COHORT` or the `tester.cohort` key of cmux.json, else
//! `default`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use base64::Engine;
use cmux_agent_pane_policy::build_identity::{BuildIdentity, BuildKind};
use serde_json::{Map, Value};

use crate::{Channel, Snapshot};

/// The `content-signing` public key (raw, base64), as `ContentSignature.publicKey` in the app.
pub const PUBLIC_KEY: &str = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4=";
/// The cached document's file name at the state root (its signature: `<name>.sig`).
pub const CACHE_NAME: &str = "flags.json";
/// The cohort of a tester who names none.
pub const DEFAULT_COHORT: &str = "default";
#[cfg(debug_assertions)]
const TEST_PUBLIC_KEY_ENV: &str = "CMUX_TUI_TEST_CONTENT_PUBLIC_KEY";

/// The remote feature keys of a layer (`schemas/features/flags-document.md`).
pub const FEATURES: &str = "Features";
pub const FEATURES_SERIAL: &str = "FeaturesSerial";
pub const FEATURES_EXPIRES_AT: &str = "FeaturesExpiresAt";
pub const FEATURES_MIN_BUILD: &str = "FeaturesMinBuild";
pub const FEATURES_MAX_BUILD: &str = "FeaturesMaxBuild";
pub const FEATURES_KEYS: [&str; 5] =
    [FEATURES, FEATURES_SERIAL, FEATURES_EXPIRES_AT, FEATURES_MIN_BUILD, FEATURES_MAX_BUILD];

/// One object of the document whose `Features*` keys are checked on their own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layer {
    /// `default`: every install.
    Default,
    /// The tester's entry under `cohorts`.
    Cohort,
}

impl Layer {
    /// The layer as `schemas/features/flags-vectors.json` names it.
    pub fn code(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Cohort => "cohort",
        }
    }
}

/// Whether `signature` (base64 text) is an Ed25519 signature of `data` by `public_key` (raw, base64).
pub fn verify(data: &[u8], signature: &[u8], public_key: &str) -> bool {
    let engine = &base64::engine::general_purpose::STANDARD;
    let Ok(signature) = engine.decode(String::from_utf8_lossy(signature).trim()) else {
        return false;
    };
    let Ok(key) = engine.decode(public_key) else { return false };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
        .verify(data, &signature)
        .is_ok()
}

/// The default's object and `cohort`'s, in that order, that `document` has.
/// None when the document is not version 1.
pub fn layers<'a>(
    document: &'a Value,
    cohort: &str,
) -> Option<Vec<(Layer, &'a Map<String, Value>)>> {
    if document.get("version").and_then(Value::as_u64) != Some(1) {
        return None;
    }
    let default = document.get(DEFAULT_COHORT).and_then(Value::as_object);
    let cohort = document.get("cohorts").and_then(|cohorts| cohorts.get(cohort));
    let layers = [(Layer::Default, default), (Layer::Cohort, cohort.and_then(Value::as_object))];
    Some(layers.into_iter().filter_map(|(layer, object)| Some((layer, object?))).collect())
}

/// The policy keys `document` sets for `cohort`: the default's, replaced by
/// the cohort's. The `Features*` keys are left out: they are read per layer,
/// so one layer's gate never applies to another's `Features`.
/// None when the document is not version 1.
pub fn resolve(document: &Value, cohort: &str) -> Option<BTreeMap<String, Value>> {
    let mut keys = BTreeMap::new();
    for (_, object) in layers(document, cohort)? {
        let policy = object.iter().filter(|(key, _)| !FEATURES_KEYS.contains(&key.as_str()));
        keys.extend(policy.map(|(key, value)| (key.clone(), value.clone())));
    }
    Some(keys)
}

/// `DisabledFeatures` of resolved keys.
pub fn disabled_features(keys: &BTreeMap<String, Value>) -> Vec<String> {
    keys.get("DisabledFeatures")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(|item| item.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

/// The public key this build trusts.
pub fn public_key() -> String {
    #[cfg(debug_assertions)]
    if let Some(key) = std::env::var(TEST_PUBLIC_KEY_ENV).ok().filter(|key| !key.is_empty()) {
        return key;
    }
    PUBLIC_KEY.to_string()
}

/// The state root (`owner-panics-*.jsonl`, the caches) for this process.
pub fn state_root() -> Option<PathBuf> {
    let sessions = cmux_tui_platform::platform::workspace_state_dir()?;
    Some(sessions.parent().map(PathBuf::from).unwrap_or(sessions))
}

/// The cached document and its signature at `root`.
pub fn cache_paths(root: &Path) -> (PathBuf, PathBuf) {
    (root.join(CACHE_NAME), root.join(format!("{CACHE_NAME}.sig")))
}

/// The cached document, when its signature verifies.
pub fn cached(root: &Path, key: &str) -> Option<Value> {
    let (data_path, signature_path) = cache_paths(root);
    let data = std::fs::read(data_path).ok()?;
    let signature = std::fs::read(signature_path).ok()?;
    if !verify(&data, &signature, key) {
        return None;
    }
    serde_json::from_slice(&data).ok()
}

/// This tester's cohort: `CMUX_TUI_COHORT`, else cmux.json `tester.cohort`, else `default`.
pub fn cohort(env: &dyn Fn(&str) -> Option<String>, settings: Option<&Value>) -> String {
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
pub fn settings() -> Option<Value> {
    std::fs::read_to_string(cmux_config::config_path())
        .ok()
        .and_then(|text| cmux_config::jsonc::parse(&text).ok())
}

/// The cohort and what the cached, verified document turns off for it.
pub fn report() -> (String, Vec<String>) {
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
pub fn disabled_now() -> Vec<String> {
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

/// A daemon's features from its inputs: the channel default, then the
/// `enable` and `disable` lists, then `disabled`, which wins.
pub fn snapshot(
    channel: Channel,
    enable: Option<&str>,
    disable: Option<&str>,
    disabled: &[String],
) -> Snapshot {
    Snapshot::from_env(channel, enable, disable).with_disabled(disabled.iter().map(String::as_str))
}

/// The daemon's features, resolved once at start: [`snapshot`] of this
/// process's [`ENABLE_ENV`](crate::ENABLE_ENV) and
/// [`DISABLE_ENV`](crate::DISABLE_ENV) and of [`disabled_now`], on the channel
/// of `kind` (the build this daemon belongs to; `None` outside any). Reads the
/// managed policy, cmux.json and the cached document: call it off any thread
/// that must not block.
pub fn daemon_snapshot(kind: Option<BuildKind>) -> Snapshot {
    let env = |name: &str| std::env::var(name).ok();
    let (enable, disable) = (env(crate::ENABLE_ENV), env(crate::DISABLE_ENV));
    snapshot(channel(kind), enable.as_deref(), disable.as_deref(), &disabled_now())
}

/// The registry channel of a build: NIGHTLY's own, RC and release builds
/// release's, DEV and staging dev's. A process outside any app bundle is a
/// release when built optimized (an npm or PyPI cmux-tui), else dev.
pub fn channel(kind: Option<BuildKind>) -> Channel {
    match kind.unwrap_or(BuildKind::Unbundled) {
        BuildKind::Nightly => Channel::Nightly,
        BuildKind::Release | BuildKind::Rc => Channel::Release,
        BuildKind::Dev | BuildKind::Staging => Channel::Dev,
        BuildKind::Unbundled if cfg!(debug_assertions) => Channel::Dev,
        BuildKind::Unbundled => Channel::Release,
    }
}

/// The kind of the cmux app bundle `exe` ships in (`<name>.app/Contents/...`,
/// its `CFBundleIdentifier`); `None` outside a cmux app.
pub fn bundle_kind(exe: &Path) -> Option<BuildKind> {
    let bundle = exe
        .ancestors()
        .find(|path| path.extension().is_some_and(|extension| extension == "app"))
        .filter(|bundle| exe.starts_with(bundle.join("Contents")))?;
    let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
    let bundle_id = info.as_dictionary()?.get("CFBundleIdentifier")?.as_string()?;
    bundle_id
        .starts_with("com.cmuxterm.app")
        .then(|| BuildIdentity::new(Some(bundle_id), None).kind())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NAME: &str = "leftoverDaemonIdleExit";

    #[test]
    fn a_disabled_feature_wins_over_the_enable_list() {
        let on = snapshot(Channel::Release, Some(NAME), None, &[]);
        assert!(on.is_enabled(crate::feature::LEFTOVER_DAEMON_IDLE_EXIT));
        let disabled = snapshot(Channel::Release, Some(NAME), None, &[NAME.to_string()]);
        assert!(!disabled.is_enabled(crate::feature::LEFTOVER_DAEMON_IDLE_EXIT));
        assert_eq!(
            disabled.source(crate::feature::LEFTOVER_DAEMON_IDLE_EXIT),
            crate::Source::Disabled
        );
    }

    #[test]
    fn each_build_kind_reads_its_channel_default() {
        assert_eq!(channel(Some(BuildKind::Nightly)), Channel::Nightly);
        assert_eq!(channel(Some(BuildKind::Release)), Channel::Release);
        assert_eq!(channel(Some(BuildKind::Rc)), Channel::Release);
        assert_eq!(channel(Some(BuildKind::Dev)), Channel::Dev);
        assert_eq!(channel(Some(BuildKind::Staging)), Channel::Dev);
        // Tests build unoptimized: an unbundled test binary is a dev build.
        assert_eq!(channel(None), Channel::Dev);
    }

    #[test]
    fn the_bundle_around_an_executable_names_its_kind() {
        let root =
            std::env::temp_dir().join(format!("cmux-features-bundle-{}", std::process::id()));
        let app = root.join("cmux NIGHTLY.app");
        let bin = app.join("Contents/Resources/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let mut info = plist::Dictionary::new();
        info.insert("CFBundleIdentifier".into(), "com.cmuxterm.app.nightly".into());
        plist::Value::Dictionary(info).to_file_xml(app.join("Contents/Info.plist")).unwrap();
        assert_eq!(bundle_kind(&bin.join("acpmux")), Some(BuildKind::Nightly));
        assert_eq!(bundle_kind(&root.join("acpmux")), None);
        let _ = std::fs::remove_dir_all(&root);
    }
}
