//! The device hub link's decisions (`DeviceHubService.swift`, `DeviceHubService+CloudAccount.swift`): when the
//! hub starts, stops or stays; the startup error codes; the identity's bundle and the build space. The
//! hub client, the identity and the keychain stay in Swift.

use serde::{Deserialize, Serialize};

/// The hub (or a start) that is up for an address and a user.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub url: String,
    pub user: String,
}

/// What `reconcile` reads.
#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq, Eq)]
#[serde(default)]
pub struct ReconcileInputs {
    /// A screen capture cleanup holds the hub as it is.
    pub capture_cleanup_active: bool,
    pub url: Option<String>,
    /// The signed-in user (empty for a user with no id), None when signed out.
    pub user: Option<String>,
    /// This Mac removed itself: the hub stays off until Sign In.
    pub left_hub: bool,
    /// The running hub's target, when a hub runs.
    pub running: Option<Target>,
    /// A start in flight.
    pub loading_for: Option<Target>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "action")]
pub enum Reconcile {
    /// Leave everything as it is.
    Keep,
    /// Stop the hub, ending its sessions; `why` for the log (address missing or set, signed in, left).
    Stop { address_set: bool, signed_in: bool, left_hub: bool },
    /// Stop whatever runs (ending its sessions), then start for this target.
    Restart { url: String, user: String },
}

pub fn reconcile(i: &ReconcileInputs) -> Reconcile {
    if i.capture_cleanup_active {
        return Reconcile::Keep;
    }
    let (Some(url), Some(user), false) = (&i.url, &i.user, i.left_hub) else {
        return Reconcile::Stop {
            address_set: i.url.is_some(),
            signed_in: i.user.is_some(),
            left_hub: i.left_hub,
        };
    };
    let target = Target { url: url.clone(), user: user.clone() };
    if i.running.as_ref() == Some(&target) || i.loading_for.as_ref() == Some(&target) {
        return Reconcile::Keep;
    }
    Reconcile::Restart { url: target.url, user: target.user }
}

/// Why the identity or the hub could not start, as the app reports it.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "error")]
pub enum StartupError {
    ConfigurationTimeout,
    SecureEnclaveUnavailable,
    Keychain { status: i64 },
    CorruptKeyBlob,
    RulesUnanswered,
    Other,
}

pub fn startup_error_code(error: &StartupError) -> String {
    match error {
        StartupError::ConfigurationTimeout => "device_hub_configuration_timeout".into(),
        StartupError::SecureEnclaveUnavailable => {
            "device_identity_secure_enclave_unavailable".into()
        }
        StartupError::Keychain { status } => format!("device_identity_keychain_{status}"),
        StartupError::CorruptKeyBlob => "device_identity_corrupt_key_blob".into(),
        StartupError::RulesUnanswered => "device_identity_rules_unanswered".into(),
        StartupError::Other => "device_identity_unavailable".into(),
    }
}

pub const DEFAULT_BUNDLE: &str = "com.cmuxterm.app.next";

/// The identity's bundle: a preview environment's own storage namespace, else the app's bundle id (the
/// NEXT id when the app has none).
pub fn hub_bundle(
    selection_bundle: Option<&str>,
    storage_namespace: Option<&str>,
    bundle_id: Option<&str>,
) -> String {
    if let Some(namespace) = storage_namespace {
        return format!("{}.cloud.{namespace}", selection_bundle.unwrap_or("cmux"));
    }
    bundle_id.filter(|b| !b.is_empty()).unwrap_or(DEFAULT_BUNDLE).to_owned()
}

/// The hub's build space: a refused data space makes no hub calls, none is NIGHTLY's, else the tag's.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "space")]
pub enum BuildSpace {
    Unusable,
    Nightly,
    Dev { header: String },
}

impl BuildSpace {
    pub fn of(refused: bool, header: Option<&str>) -> Self {
        match (refused, header) {
            (true, _) => Self::Unusable,
            (false, None) => Self::Nightly,
            (false, Some(h)) => Self::Dev { header: h.to_owned() },
        }
    }

    /// Only NIGHTLY's hub may run in acpmux's remote host.
    pub fn allows_remote_hub(&self) -> bool {
        *self == Self::Nightly
    }
}

/// The account's user id: signed in, its id (empty with none); signed out, None.
pub fn user_id(signed_in: bool, id: Option<&str>) -> Option<String> {
    signed_in.then(|| id.unwrap_or_default().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(url: &str, user: &str) -> Option<Target> {
        Some(Target { url: url.into(), user: user.into() })
    }

    fn signed_in() -> ReconcileInputs {
        ReconcileInputs {
            url: Some("https://hub".into()),
            user: Some("u1".into()),
            ..Default::default()
        }
    }

    #[test]
    fn the_hub_starts_once_per_address_and_user() {
        assert_eq!(
            reconcile(&signed_in()),
            Reconcile::Restart { url: "https://hub".into(), user: "u1".into() }
        );
        let running = ReconcileInputs { running: t("https://hub", "u1"), ..signed_in() };
        assert_eq!(reconcile(&running), Reconcile::Keep);
        let loading = ReconcileInputs { loading_for: t("https://hub", "u1"), ..signed_in() };
        assert_eq!(reconcile(&loading), Reconcile::Keep);
        let other_user = ReconcileInputs { running: t("https://hub", "u2"), ..signed_in() };
        assert!(matches!(reconcile(&other_user), Reconcile::Restart { .. }));
    }

    #[test]
    fn signed_out_no_address_or_left_stops_and_cleanup_holds() {
        let out = ReconcileInputs { user: None, ..signed_in() };
        assert_eq!(
            reconcile(&out),
            Reconcile::Stop { address_set: true, signed_in: false, left_hub: false }
        );
        let left =
            ReconcileInputs { left_hub: true, running: t("https://hub", "u1"), ..signed_in() };
        assert_eq!(
            reconcile(&left),
            Reconcile::Stop { address_set: true, signed_in: true, left_hub: true }
        );
        let none = ReconcileInputs { url: None, ..signed_in() };
        assert!(matches!(reconcile(&none), Reconcile::Stop { address_set: false, .. }));
        let held = ReconcileInputs { capture_cleanup_active: true, url: None, ..signed_in() };
        assert_eq!(reconcile(&held), Reconcile::Keep);
    }

    #[test]
    fn startup_errors_have_stable_codes() {
        assert_eq!(
            startup_error_code(&StartupError::Keychain { status: -25300 }),
            "device_identity_keychain_-25300"
        );
        assert_eq!(startup_error_code(&StartupError::Other), "device_identity_unavailable");
        assert_eq!(
            startup_error_code(&StartupError::ConfigurationTimeout),
            "device_hub_configuration_timeout"
        );
    }

    #[test]
    fn the_bundle_and_build_space() {
        assert_eq!(hub_bundle(Some("com.x"), Some("pr-12"), Some("app")), "com.x.cloud.pr-12");
        assert_eq!(hub_bundle(None, Some("pr-12"), None), "cmux.cloud.pr-12");
        assert_eq!(hub_bundle(None, None, Some("")), DEFAULT_BUNDLE);
        assert_eq!(hub_bundle(None, None, Some("com.example.app")), "com.example.app");
        // DeviceHubBuildSpaceTests: a DEV build with no usable tag sends nothing; NIGHTLY names none.
        assert_eq!(BuildSpace::of(true, Some("dev:tag-a")), BuildSpace::Unusable);
        assert_eq!(BuildSpace::of(false, None), BuildSpace::Nightly);
        assert_eq!(
            BuildSpace::of(false, Some("dev:tag-a")),
            BuildSpace::Dev { header: "dev:tag-a".into() }
        );
        assert!(
            BuildSpace::Nightly.allows_remote_hub() && !BuildSpace::Unusable.allows_remote_hub()
        );
        assert_eq!(user_id(true, None), Some(String::new()));
        assert_eq!(user_id(false, Some("u")), None);
    }
}
