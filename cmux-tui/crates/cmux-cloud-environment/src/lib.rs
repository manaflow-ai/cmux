//! Runtime NEXT Cloud environment selection.
//!
//! This crate is deliberately independent of the app shell.  It owns the one
//! backend allowlist and client-config cache used by the CLI, daemon and Swift bridge. It persists only
//! the selected environment name and sign-in revision. Secrets (Stack tokens) remain in the
//! environment-specific Keychain namespace owned by the app.

mod client_config;

pub use client_config::{
    ADVANCED_CREATE_FIELDS, ClientConfig, ConfigSource, check_create_capabilities,
};

use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::ops::Deref;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const STATE_FILE: &str = "cloud-environment.json";
const DEV_BUNDLE: &str = "com.cmuxterm.app.debug";
const NIGHTLY_BUNDLE: &str = "com.cmuxterm.app.nightly.cmux-next";

/// A supported NEXT Cloud deployment.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Environment {
    Local,
    /// An explicit loopback API origin; the backend supplies the other origins.
    LocalOrigin(String),
    Dev,
    Preview(u32),
    Staging,
    Prod,
}

impl Environment {
    pub fn parse(value: &str) -> Result<Self, String> {
        let value = value.trim();
        if value.contains("://") {
            return Self::from_origin(value);
        }
        let normalized = value.to_ascii_lowercase();
        match normalized.as_str() {
            "local" => Ok(Self::Local),
            "dev" | "development" => Ok(Self::Dev),
            "staging" => Ok(Self::Staging),
            "prod" | "production" => Ok(Self::Prod),
            _ => {
                let Some(number) = normalized.strip_prefix("preview-") else {
                    return Err(format!("unknown cloud environment: {value}"));
                };
                if number.is_empty() || !number.bytes().all(|byte| byte.is_ascii_digit()) {
                    return Err(format!("invalid preview environment: {value}"));
                }
                let number = number
                    .parse::<u32>()
                    .map_err(|_| format!("invalid preview environment: {value}"))?;
                if number == 0 {
                    return Err("preview number must be greater than zero".into());
                }
                Ok(Self::Preview(number))
            }
        }
    }

    /// Accept only declared API deployments or explicit HTTP loopback.
    fn from_origin(value: &str) -> Result<Self, String> {
        let origin = client_config::bare_origin(value)?;
        match origin.as_str() {
            DEVELOPMENT_API => Ok(Self::Dev),
            STAGING_API => Ok(Self::Staging),
            PRODUCTION_API => Ok(Self::Prod),
            "http://localhost:8787" => Ok(Self::Local),
            _ if client_config::is_loopback_origin(&origin) => Ok(Self::LocalOrigin(origin)),
            _ => {
                let host = url::Url::parse(&origin)
                    .map_err(|error| error.to_string())?
                    .host_str()
                    .unwrap_or("")
                    .to_owned();
                let number = host
                    .strip_prefix("cmux-api-preview-")
                    .and_then(|tail| tail.strip_suffix(".debussy.workers.dev"));
                match number {
                    Some(number) if origin == format!("https://{host}") => {
                        Self::parse(&format!("preview-{number}"))
                    }
                    _ => Err(format!("cloud backend origin is not allowlisted: {value}")),
                }
            }
        }
    }

    pub fn name(&self) -> String {
        match self {
            Self::Local => "local".into(),
            Self::LocalOrigin(origin) => origin.clone(),
            Self::Dev => "dev".into(),
            Self::Preview(number) => format!("preview-{number}"),
            Self::Staging => "staging".into(),
            Self::Prod => "prod".into(),
        }
    }

    pub fn configuration(&self) -> Configuration {
        let deployment = match self {
            Self::Local | Self::LocalOrigin(_) => LOCAL_DEPLOYMENT,
            Self::Dev | Self::Preview(_) => DEVELOPMENT_DEPLOYMENT,
            Self::Staging => STAGING_DEPLOYMENT,
            Self::Prod => PRODUCTION_DEPLOYMENT,
        };
        let api_origin = match self {
            Self::LocalOrigin(origin) => origin.clone(),
            Self::Preview(number) => {
                format!("https://cmux-api-preview-{number}.debussy.workers.dev")
            }
            _ => deployment.api_origin.into(),
        };
        Configuration {
            name: self.name(),
            api_origin,
            auth_web_origin: deployment.auth_web_origin.into(),
            vm_origin: deployment.vm_origin.into(),
            platform_origin: deployment.platform_origin.into(),
            mobile_origin: deployment.mobile_origin.into(),
            device_hub_origin: deployment.device_hub_origin.into(),
            share_room_origin: deployment.platform_origin.into(),
            // Previews use the development room, whose install-token issuer
            // remains the development API.
            share_api_origin: deployment.api_origin.into(),
            stack_origin: STACK_ORIGIN.into(),
            stack_project_id: deployment.stack_project_id.into(),
            stack_client_key: deployment.stack_client_key.into(),
        }
    }
}

pub const DEVELOPMENT_API: &str = "https://cmux-api-development.debussy.workers.dev";
pub const STAGING_API: &str = "https://cloud-api-staging.cmux.dev";
pub const PRODUCTION_API: &str = "https://cloud-api.cmux.dev";
pub const DEVELOPMENT_PLATFORM: &str = "https://cmux-platform-development.debussy.workers.dev";
pub const STAGING_PLATFORM: &str = "https://cmux-platform-staging.debussy.workers.dev";
pub const PRODUCTION_PLATFORM: &str = "https://cmux-platform-production.debussy.workers.dev";
pub const STACK_ORIGIN: &str = "https://api.stack-auth.com";
pub const DEVELOPMENT_STACK_PROJECT: &str = "454ecd03-1db2-4050-845e-4ce5b0cd9895";
pub const DEVELOPMENT_STACK_CLIENT_KEY: &str = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g";
pub const PRODUCTION_STACK_PROJECT: &str = "9790718f-14cd-4f7e-824d-eaf527a82b82";

/// A static deployment row. Preview changes only the API origin of development.
#[derive(Clone, Copy, Debug)]
pub struct Deployment {
    pub api_origin: &'static str,
    pub auth_web_origin: &'static str,
    pub vm_origin: &'static str,
    pub platform_origin: &'static str,
    pub mobile_origin: &'static str,
    pub device_hub_origin: &'static str,
    pub stack_project_id: &'static str,
    pub stack_client_key: &'static str,
}

pub const DEVELOPMENT_DEPLOYMENT: Deployment = Deployment {
    api_origin: DEVELOPMENT_API,
    auth_web_origin: "https://cmux-staging.vercel.app",
    vm_origin: "https://vm-staging.cmux.dev",
    platform_origin: DEVELOPMENT_PLATFORM,
    mobile_origin: "https://cmux-mobile-api-dev.debussy.workers.dev",
    device_hub_origin: "https://cmux-device-hub-dev.debussy.workers.dev",
    stack_project_id: DEVELOPMENT_STACK_PROJECT,
    stack_client_key: DEVELOPMENT_STACK_CLIENT_KEY,
};
pub const STAGING_DEPLOYMENT: Deployment = Deployment {
    api_origin: STAGING_API,
    platform_origin: STAGING_PLATFORM,
    ..DEVELOPMENT_DEPLOYMENT
};
pub const PRODUCTION_DEPLOYMENT: Deployment = Deployment {
    api_origin: PRODUCTION_API,
    auth_web_origin: "https://cmux.com",
    vm_origin: "https://vm.cmux.dev",
    platform_origin: PRODUCTION_PLATFORM,
    mobile_origin: "https://mobile-api.cmux.dev",
    device_hub_origin: "https://cmux-device-hub.debussy.workers.dev",
    stack_project_id: PRODUCTION_STACK_PROJECT,
    stack_client_key: "",
};
/// Local worker ports used by the NEXT Cloud development stack. Mobile and
/// device hub have no local unified launcher yet; each gets a separate port.
pub const LOCAL_DEPLOYMENT: Deployment = Deployment {
    api_origin: "http://localhost:8787",
    auth_web_origin: "http://localhost:3777",
    vm_origin: "http://localhost:8789",
    platform_origin: "http://localhost:8788",
    mobile_origin: "http://localhost:8790",
    device_hub_origin: "http://localhost:8791",
    ..DEVELOPMENT_DEPLOYMENT
};

/// All non-secret origins and Stack project credentials for one environment.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub struct Configuration {
    pub name: String,
    pub api_origin: String,
    pub auth_web_origin: String,
    pub vm_origin: String,
    pub platform_origin: String,
    pub mobile_origin: String,
    pub device_hub_origin: String,
    pub share_room_origin: String,
    pub share_api_origin: String,
    pub stack_origin: String,
    pub stack_project_id: String,
    pub stack_client_key: String,
}

/// Resolved state returned by `cloud env get|set` and the Swift bridge.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Selection {
    #[serde(flatten)]
    pub configuration: Configuration,
    pub bundle_id: String,
    pub mutable: bool,
    pub auth_namespace: String,
    /// Rust's complete auth token/defaults storage suffix. None preserves the
    /// original production service; signed DEV retains its old Stack suffix.
    pub auth_storage_namespace: Option<String>,
    /// Untouched default: keep existing sign-in and pairing storage on update.
    pub legacy_storage: bool,
    pub state_path: String,
    #[serde(default)]
    pub config_source: ConfigSource,
    #[serde(default)]
    pub client_config_version: Option<u32>,
    #[serde(default)]
    pub capabilities: serde_json::Value,
    #[serde(default)]
    pub image_channel: Option<String>,
}

impl Deref for Selection {
    type Target = Configuration;
    fn deref(&self) -> &Self::Target {
        &self.configuration
    }
}

/// Reads and atomically updates one bundle's selected environment.
/// This is the sole resolver for the per-bundle Cloud selection state root.
pub struct Resolver {
    bundle_id: String,
    home: PathBuf,
}

impl Resolver {
    pub fn new(bundle_id: &str, home: &Path) -> Result<Self, String> {
        validate_bundle_id(bundle_id)?;
        if !home.is_absolute() {
            return Err("home path must be absolute".into());
        }
        Ok(Self { bundle_id: bundle_id.into(), home: home.to_path_buf() })
    }

    pub fn resolve(&self, seed: Option<&str>) -> Result<Selection, String> {
        // Launch overrides are authoritative for this launch only. Never
        // overwrite a persisted picker choice. Release accepts only the same
        // origin allowlist enforced by Environment::parse.
        if let Some(seed) = seed.filter(|value| !value.trim().is_empty()) {
            let environment = Environment::parse(seed)?;
            if !self.mutable() && matches!(environment, Environment::LocalOrigin(_)) {
                return Err(format!(
                    "cloud environment origin is not allowlisted for bundle {}",
                    self.bundle_id
                ));
            }
            let mut selection = self.selection(environment, 0)?;
            // An explicit override must never adopt a previous default's
            // credentials or pairing, even when it spells the default backend.
            selection.legacy_storage = false;
            selection.auth_storage_namespace = Some(selection.auth_namespace.clone());
            return Ok(selection);
        }
        if !self.mutable() {
            return self.selection(Environment::Prod, 0);
        }
        let path = self.state_path();
        let persisted = match fs::read_to_string(&path) {
            Ok(text) => Some(serde_json::from_str::<Persisted>(&text).map_err(|error| {
                format!("invalid cloud environment state {}: {error}", path.display())
            })?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(format!("read {}: {error}", path.display())),
        };
        if let Some(persisted) = persisted {
            let environment = Environment::parse(&persisted.name)?;
            // #35133 wrote the first default state with a generated revision
            // and no marker. Preserve that user's existing credentials. New
            // explicit sets carry `explicit: true`, so switching back to a
            // default never silently adopts legacy storage.
            let legacy_seed = persisted.explicit != Some(true);
            return self.selection_with_legacy(
                environment,
                persisted.revision.unwrap_or(0),
                Some(legacy_seed),
            );
        }
        let environment = self.default_environment();
        let revision = if environment == self.default_environment() { 0 } else { next_revision() };
        match self.persist_new(&environment, revision) {
            Ok(()) => self.selection(environment, revision),
            Err(error) if error.starts_with("state already exists:") => {
                // Another process won the first-launch race. Never overwrite
                // its choice; return the winner's state.
                let text = fs::read_to_string(&path)
                    .map_err(|read| format!("read {}: {read}", path.display()))?;
                let winner: Persisted = serde_json::from_str(&text).map_err(|parse| {
                    format!("invalid cloud environment state {}: {parse}", path.display())
                })?;
                let environment = Environment::parse(&winner.name)?;
                self.selection_with_legacy(
                    environment,
                    winner.revision.unwrap_or(0),
                    Some(winner.explicit != Some(true)),
                )
            }
            Err(error) => Err(error),
        }
    }

    pub fn set(&self, environment: Environment) -> Result<Selection, String> {
        // Validate even enum values constructed directly by another crate.
        Environment::parse(&environment.configuration().api_origin)?;
        if !self.mutable() {
            return Err(format!(
                "cloud environment is fixed to prod for bundle {}",
                self.bundle_id
            ));
        }
        // An explicit set is also the recovery path for invalid persisted
        // JSON. Unreadable state still fails; never hide permissions/I/O errors.
        let path = self.state_path();
        match fs::read_to_string(&path) {
            Ok(text) => {
                if let Ok(current) = serde_json::from_str::<Persisted>(&text)
                    && Environment::parse(&current.name).ok().as_ref() == Some(&environment)
                {
                    return self.selection_with_legacy(
                        environment,
                        current.revision.unwrap_or(0),
                        Some(current.explicit != Some(true)),
                    );
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("read {}: {error}", path.display())),
        }
        let revision = next_revision();
        self.persist_replace(&environment, revision)?;
        self.selection(environment, revision)
    }

    /// Fetch and validate the backend's client configuration, falling back
    /// to a validated per-backend cache on transport/server errors.
    pub async fn client_config(&self, selection: Selection) -> Result<Selection, String> {
        client_config::resolve(self, selection).await
    }

    /// Applies a previously fetched, validated client-config cache without
    /// performing network I/O. Daemon consumers use this after CLI bootstrap.
    pub fn cached_client_config(&self, selection: Selection) -> Result<Option<Selection>, String> {
        client_config::cached(self, selection)
    }

    pub fn state_path(&self) -> PathBuf {
        self.home.join("Library/Application Support/cmux").join(&self.bundle_id).join(STATE_FILE)
    }

    pub fn bundle_id(&self) -> &str {
        &self.bundle_id
    }
    pub fn mutable(&self) -> bool {
        is_mutable_bundle(&self.bundle_id)
    }

    fn default_environment(&self) -> Environment {
        if self.mutable() && self.bundle_id != NIGHTLY_BUNDLE {
            Environment::Dev
        } else {
            Environment::Prod
        }
    }

    fn selection(&self, environment: Environment, revision: u64) -> Result<Selection, String> {
        self.selection_with_legacy(environment, revision, None)
    }

    fn selection_with_legacy(
        &self,
        environment: Environment,
        revision: u64,
        legacy_hint: Option<bool>,
    ) -> Result<Selection, String> {
        let configuration = environment.configuration();
        Environment::parse(&configuration.api_origin)?;
        // These are the only historical defaults with known credential and
        // pairing destinations. Debug/tagged bundles allowed arbitrary old
        // overrides, so they cannot safely adopt unscoped previous state.
        let legacy_storage = legacy_hint.unwrap_or(revision == 0)
            && match self.bundle_id.as_str() {
                "com.cmuxterm.app.debug.next" => environment == Environment::Dev,
                "com.cmuxterm.app" | "com.cmuxterm.app.rc" | NIGHTLY_BUNDLE => {
                    environment == Environment::Prod
                }
                bundle if bundle.starts_with("com.cmuxterm.app.rc.") => {
                    environment == Environment::Prod
                }
                _ => false,
            };
        let auth_namespace = format!("{}-{revision}", namespace(&configuration.api_origin));
        let auth_storage_namespace = if legacy_storage {
            (self.bundle_id == "com.cmuxterm.app.debug.next")
                .then(|| configuration.stack_project_id.clone())
        } else {
            Some(auth_namespace.clone())
        };
        Ok(Selection {
            legacy_storage,
            auth_namespace,
            auth_storage_namespace,
            configuration,
            bundle_id: self.bundle_id.clone(),
            mutable: self.mutable(),
            state_path: self.state_path().display().to_string(),
            config_source: ConfigSource::KnownOriginFallback,
            client_config_version: None,
            // Compatibility fallback has no capability declaration. Any
            // advanced create field therefore fails closed until the backend
            // publishes its current support through `/v1/client-config`.
            // The compatibility table supplies origins only. Until the backend
            // publishes `/v1/client-config`, every capability-dependent create
            // option fails closed rather than being silently discarded.
            capabilities: serde_json::json!({"machine_create": {"size": true, "name": true}}),
            image_channel: None,
        })
    }

    fn persist_new(&self, environment: &Environment, revision: u64) -> Result<(), String> {
        let path = self.state_path();
        let parent =
            path.parent().ok_or_else(|| "cloud environment state has no parent".to_string())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("create {}: {error}", parent.display()))?;
        let tmp = temp_path(parent);
        let body = serde_json::to_vec(&Persisted {
            name: environment.name(),
            revision: Some(revision),
            explicit: Some(false),
        })
        .map_err(|error| error.to_string())?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file =
            options.open(&tmp).map_err(|error| format!("create {}: {error}", tmp.display()))?;
        let result = (|| {
            file.write_all(&body).map_err(|error| format!("write {}: {error}", tmp.display()))?;
            file.sync_all().map_err(|error| format!("sync {}: {error}", tmp.display()))?;
            drop(file);
            fs::hard_link(&tmp, &path).map_err(|error| {
                if error.kind() == std::io::ErrorKind::AlreadyExists {
                    "state already exists: another resolver won".to_string()
                } else {
                    format!("publish {}: {error}", path.display())
                }
            })?;
            sync_directory(parent)
        })();
        let _ = fs::remove_file(&tmp);
        result
    }

    fn persist_replace(&self, environment: &Environment, revision: u64) -> Result<(), String> {
        let path = self.state_path();
        let parent =
            path.parent().ok_or_else(|| "cloud environment state has no parent".to_string())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("create {}: {error}", parent.display()))?;
        let tmp = temp_path(parent);
        let body = serde_json::to_vec(&Persisted {
            name: environment.name(),
            revision: Some(revision),
            explicit: Some(true),
        })
        .map_err(|error| error.to_string())?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file =
            options.open(&tmp).map_err(|error| format!("create {}: {error}", tmp.display()))?;
        let result = (|| {
            file.write_all(&body).map_err(|error| format!("write {}: {error}", tmp.display()))?;
            file.sync_all().map_err(|error| format!("sync {}: {error}", tmp.display()))?;
            drop(file);
            fs::rename(&tmp, &path)
                .map_err(|error| format!("replace {}: {error}", path.display()))?;
            sync_directory(parent)
        })();
        let _ = fs::remove_file(&tmp);
        result
    }
}

/// Deterministic, path-safe and collision-free for canonical origins.
fn namespace(origin: &str) -> String {
    origin.bytes().map(|byte| format!("{byte:02x}")).collect()
}

fn sync_directory(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("sync {}: {error}", path.display()))?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[derive(Deserialize, Serialize)]
struct Persisted {
    name: String,
    #[serde(default)]
    revision: Option<u64>,
    /// Missing means the pre-marker state format from #35133. Such a state
    /// may be the first-launch default and is retained for continuity.
    #[serde(default)]
    explicit: Option<bool>,
}

static REVISION: AtomicU64 = AtomicU64::new(1);

fn next_revision() -> u64 {
    let clock = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX))
        .unwrap_or(0);
    clock.wrapping_add(REVISION.fetch_add(1, Ordering::Relaxed))
}

fn temp_path(parent: &Path) -> PathBuf {
    parent.join(format!(".{STATE_FILE}.{}.{}.tmp", std::process::id(), next_revision()))
}

fn is_mutable_bundle(bundle_id: &str) -> bool {
    bundle_id == NIGHTLY_BUNDLE
        || bundle_id == DEV_BUNDLE
        || bundle_id.starts_with("com.cmuxterm.app.debug.")
}

fn validate_bundle_id(bundle_id: &str) -> Result<(), String> {
    if bundle_id.is_empty()
        || bundle_id == "."
        || bundle_id == ".."
        || bundle_id.contains('/')
        || bundle_id.contains('\\')
        || bundle_id.chars().any(char::is_control)
    {
        return Err("invalid bundle identifier".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    pub(super) struct Home(pub(super) PathBuf);
    impl Home {
        pub(super) fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "cmux-cloud-env-test-{}-{}",
                std::process::id(),
                next_revision()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Home {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn table_has_distinct_preview_namespace() {
        let preview = Environment::Preview(42).configuration();
        assert_eq!(preview.name, "preview-42");
        assert!(preview.api_origin.contains("preview-42"));
        assert_eq!(preview.platform_origin, Environment::Dev.configuration().platform_origin);
        assert_eq!(preview.share_api_origin, DEVELOPMENT_API);
    }

    #[test]
    fn launch_override_wins_without_overwriting_persisted_choice() {
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        resolver.set(Environment::Staging).unwrap();
        assert_eq!(resolver.resolve(Some("prod")).unwrap().name, "prod");
        assert_eq!(resolver.resolve(None).unwrap().name, "staging");
    }

    #[test]
    fn release_accepts_allowlisted_launch_override_and_keeps_legacy_default() {
        let home = Home::new();
        let resolver = Resolver::new("com.cmuxterm.app", &home.0).unwrap();
        let default = resolver.resolve(None).unwrap();
        assert_eq!(default.name, "prod");
        assert!(default.legacy_storage);
        assert_eq!(resolver.resolve(Some("dev")).unwrap().name, "dev");
        assert!(resolver.resolve(Some("https://untrusted.example")).is_err());
        assert!(resolver.set(Environment::Dev).is_err());
    }

    #[test]
    fn real_switch_rotates_sign_in_namespace_but_same_selection_does_not() {
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        let initial = resolver.resolve(None).unwrap();
        assert_eq!(initial.name, "dev");
        assert!(!initial.legacy_storage);
        assert_eq!(resolver.set(Environment::Dev).unwrap().auth_namespace, initial.auth_namespace);
        let staging = resolver.set(Environment::Staging).unwrap();
        assert!(!staging.legacy_storage);
        assert_ne!(staging.auth_namespace, initial.auth_namespace);
        assert_eq!(resolver.resolve(None).unwrap().auth_namespace, staging.auth_namespace);
        assert_ne!(resolver.set(Environment::Dev).unwrap().auth_namespace, initial.auth_namespace);
    }

    #[test]
    fn invalid_persistence_fails_closed_and_bundle_cannot_traverse() {
        let home = Home::new();
        assert!(Resolver::new("../other", &home.0).is_err());
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        resolver.resolve(None).unwrap();
        fs::write(resolver.state_path(), "{bad").unwrap();
        assert!(resolver.resolve(None).is_err());
        assert_eq!(resolver.resolve(Some("prod")).unwrap().name, "prod");
        assert_eq!(resolver.set(Environment::Prod).unwrap().name, "prod");
        assert_eq!(resolver.resolve(None).unwrap().name, "prod");
    }

    #[test]
    fn safe_untouched_defaults_preserve_historical_storage_only() {
        let home = Home::new();
        for bundle in
            ["com.cmuxterm.app", "com.cmuxterm.app.rc", "com.cmuxterm.app.rc.test", NIGHTLY_BUNDLE]
        {
            let resolver = Resolver::new(bundle, &home.0).unwrap();
            let selected = resolver.resolve(None).unwrap();
            assert!(selected.legacy_storage, "{bundle}");
            assert_eq!(selected.auth_storage_namespace, None);
            let explicit = resolver.resolve(Some("prod")).unwrap();
            assert!(!explicit.legacy_storage);
            assert_eq!(explicit.auth_storage_namespace, Some(explicit.auth_namespace));
        }
        let resolver = Resolver::new("com.cmuxterm.app.debug.next", &home.0).unwrap();
        let selected = resolver.resolve(None).unwrap();
        assert!(selected.legacy_storage);
        assert_eq!(selected.auth_storage_namespace.as_deref(), Some(DEVELOPMENT_STACK_PROJECT));
        let switched = resolver.set(Environment::Staging).unwrap();
        assert!(!switched.legacy_storage);
        assert_eq!(switched.auth_storage_namespace, Some(switched.auth_namespace.clone()));
        let returned = resolver.set(Environment::Dev).unwrap();
        assert!(!returned.legacy_storage);
        assert_eq!(returned.auth_storage_namespace, Some(returned.auth_namespace.clone()));
        assert_ne!(returned.auth_storage_namespace, selected.auth_storage_namespace);
    }

    #[test]
    fn unknown_debug_history_never_restores_unscoped_credentials() {
        let home = Home::new();
        for bundle in [DEV_BUNDLE, "com.cmuxterm.app.debug.tagged", "com.cmuxterm.app.debug.nextx"]
        {
            let selected = Resolver::new(bundle, &home.0).unwrap().resolve(None).unwrap();
            assert!(!selected.legacy_storage, "{bundle}");
            assert_eq!(selected.auth_storage_namespace, Some(selected.auth_namespace));
        }
    }

    #[test]
    fn backend_origin_aliases_remain_within_the_declared_allowlist() {
        for (origin, expected) in [
            (PRODUCTION_API, Environment::Prod),
            (STAGING_API, Environment::Staging),
            (DEVELOPMENT_API, Environment::Dev),
            ("https://cmux-api-preview-123.debussy.workers.dev", Environment::Preview(123)),
        ] {
            assert_eq!(Environment::parse(origin).unwrap(), expected);
        }
        for origin in [
            "https://cloud-api.cmux.dev.attacker.example",
            "https://user@cloud-api.cmux.dev",
            "https://cloud-api.cmux.dev/extra",
            "https://cloud-api.cmux.dev?query=x",
            "http://cloud-api.cmux.dev",
            "https://cmux-api-preview-0.debussy.workers.dev",
        ] {
            assert!(Environment::parse(origin).is_err(), "{origin}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn persistence_permissions_do_not_depend_on_umask() {
        use std::os::unix::fs::PermissionsExt;
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        resolver.set(Environment::Staging).unwrap();
        assert_eq!(
            fs::metadata(resolver.state_path()).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
