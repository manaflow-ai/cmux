//! Runtime NEXT Cloud environment selection.
//!
//! This crate is deliberately independent of the app shell.  It owns the one
//! backend allowlist and client-config cache used by the CLI, daemon and Swift bridge. It persists only
//! the selected environment name and sign-in revision. Secrets (Stack tokens) remain in the
//! environment-specific Keychain namespace owned by the app.

mod client_config;
mod state_root;

pub use client_config::{
    ADVANCED_CREATE_FIELDS, ClientConfig, ConfigSource, check_create_capabilities,
};
pub use state_root::{STATE_ROOT_ENV, run_segment, state_root, state_root_from_env};

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
/// A dev build's own backend, written by the tag's hand-off (`cmux-next-ios/scripts/review.sh
/// --backend`) next to [`STATE_FILE`]: `{"backend": "<origin or name>"}`. Read only by dev bundles
/// ([`is_dev_bundle`]); a release, RC or NIGHTLY bundle never looks for it.
pub const BACKEND_FILE: &str = "backend.json";
const DEV_BUNDLE: &str = "com.cmuxterm.app.debug";
const NIGHTLY_BUNDLE: &str = "com.cmuxterm.app.nightly.cmux-next";
/// The bundle id shipped NEXT Nightly builds carry (`nightly-next`).
const SHIPPED_NIGHTLY_BUNDLE: &str = "com.cmuxterm.app.nightly";

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
    /// A dev build's own backend: one tag's `wrangler dev` stack on the dev VM, by its tailnet origin
    /// (`https://<host>.<tailnet>.ts.net[:port]`) or its public one (`https://api.s<N>.wdev.cmux.dev`,
    /// behind the authenticating gateway, scripts/cmux-next/cloud-dev-stack/gateway). HTTPS only. Dev
    /// bundles only ([`is_dev_bundle`]); its other origins are the development deployment's unless
    /// its client-config names others.
    Tailnet(String),
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
            _ if client_config::is_tailnet_origin(&origin)
                || client_config::is_public_stack_origin(&origin) =>
            {
                Ok(Self::Tailnet(origin))
            }
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
            Self::LocalOrigin(origin) | Self::Tailnet(origin) => origin.clone(),
            Self::Dev => "dev".into(),
            Self::Preview(number) => format!("preview-{number}"),
            Self::Staging => "staging".into(),
            Self::Prod => "prod".into(),
        }
    }

    pub fn configuration(&self) -> Configuration {
        let deployment = match self {
            Self::Local | Self::LocalOrigin(_) => LOCAL_DEPLOYMENT,
            Self::Dev | Self::Preview(_) | Self::Tailnet(_) => DEVELOPMENT_DEPLOYMENT,
            Self::Staging => STAGING_DEPLOYMENT,
            Self::Prod => PRODUCTION_DEPLOYMENT,
        };
        let api_origin = match self {
            Self::LocalOrigin(origin) | Self::Tailnet(origin) => origin.clone(),
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
            share_room_origin: deployment.share_origin.into(),
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
/// Each platform deployment's short chat share host (cmux-platform `SHARE_PAGE_ORIGIN`, a custom domain of
/// the same Worker): links made there and on the platform origin are the same deployment's.
pub const DEVELOPMENT_SHARE: &str = "https://share-dev.cmux.dev";
pub const STAGING_SHARE: &str = "https://share-staging.cmux.dev";
pub const PRODUCTION_SHARE: &str = "https://share.cmux.dev";
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
    /// The chat share room: the platform deployment's short share host, so links read `share.cmux.dev/g/...`.
    pub share_origin: &'static str,
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
    share_origin: DEVELOPMENT_SHARE,
    mobile_origin: "https://cmux-mobile-api-dev.debussy.workers.dev",
    device_hub_origin: "https://cmux-device-hub-dev.debussy.workers.dev",
    stack_project_id: DEVELOPMENT_STACK_PROJECT,
    stack_client_key: DEVELOPMENT_STACK_CLIENT_KEY,
};
pub const STAGING_DEPLOYMENT: Deployment = Deployment {
    api_origin: STAGING_API,
    platform_origin: STAGING_PLATFORM,
    share_origin: STAGING_SHARE,
    ..DEVELOPMENT_DEPLOYMENT
};
pub const PRODUCTION_DEPLOYMENT: Deployment = Deployment {
    api_origin: PRODUCTION_API,
    auth_web_origin: "https://cmux.com",
    vm_origin: "https://vm.cmux.dev",
    platform_origin: PRODUCTION_PLATFORM,
    share_origin: PRODUCTION_SHARE,
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
    share_origin: "http://localhost:8788",
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
    /// Where this launch's backend came from when it is not the bundle's own choice: `launch`
    /// (`--cloud-backend` or `CMUX_NEXT_CLOUD_BACKEND`/`CMUX_NEXT_CLOUD_ENV`) or `tag_file` (the dev
    /// build's [`BACKEND_FILE`]). None: the persisted picker choice or the bundle's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backend_override: Option<String>,
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
    /// The launch's state root's run segment ([`state_root::run_segment`]), when it has one.
    run: Option<String>,
}

impl Resolver {
    /// The resolver of `bundle_id` for `home`, or for this process's state root
    /// ([`STATE_ROOT_ENV`]) when it has one.
    pub fn new(bundle_id: &str, home: &Path) -> Result<Self, String> {
        Self::with_state_root(bundle_id, home, state_root_from_env().as_deref())
    }

    /// The resolver of `bundle_id` for `home`; with `state_root`, the root stands for the home and
    /// every selection's sign-in namespace carries the root's run segment.
    pub fn with_state_root(
        bundle_id: &str,
        home: &Path,
        state_root: Option<&Path>,
    ) -> Result<Self, String> {
        validate_bundle_id(bundle_id)?;
        let home = state_root.unwrap_or(home);
        if !home.is_absolute() {
            return Err("home path must be absolute".into());
        }
        move_from_classic(home, bundle_id);
        Ok(Self {
            bundle_id: bundle_id.into(),
            home: home.to_path_buf(),
            run: state_root.map(run_segment),
        })
    }

    /// This launch's backend, in order: `seed` (the launch's `--cloud-backend`, else its
    /// `CMUX_NEXT_CLOUD_BACKEND`/`CMUX_NEXT_CLOUD_ENV`), then a dev build's [`BACKEND_FILE`], then the
    /// persisted picker choice, then the bundle's default.
    pub fn resolve(&self, seed: Option<&str>) -> Result<Selection, String> {
        self.resolve_from(seed, true)
    }

    /// The picker's own choice (`cloud env get --persisted`): no launch seed and no tag file.
    pub fn resolve_persisted(&self) -> Result<Selection, String> {
        self.resolve_from(None, false)
    }

    /// The dev build's [`BACKEND_FILE`] value, when there is one. A release, RC or NIGHTLY bundle
    /// never reads it. Unreadable or malformed fails closed: the launch says why instead of
    /// silently using another backend.
    pub fn tag_backend(&self) -> Result<Option<String>, String> {
        if !self.dev_build() {
            return Ok(None);
        }
        let path = self.backend_path();
        let text = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(format!("read {}: {error}", path.display())),
        };
        let file: BackendFile = serde_json::from_str(&text)
            .map_err(|error| format!("invalid {}: {error}", path.display()))?;
        let backend = file.backend.trim();
        Ok((!backend.is_empty()).then(|| backend.to_owned()))
    }

    /// `<bundle folder>/backend.json`, the dev build's own backend ([`BACKEND_FILE`]).
    pub fn backend_path(&self) -> PathBuf {
        bundle_folder(&self.home, &self.bundle_id).join(BACKEND_FILE)
    }

    fn resolve_from(&self, seed: Option<&str>, tag_file: bool) -> Result<Selection, String> {
        // Launch overrides are authoritative for this launch only. Never
        // overwrite a persisted picker choice. Release accepts only the same
        // origin allowlist enforced by Environment::parse.
        if let Some(seed) = seed.filter(|value| !value.trim().is_empty()) {
            return self.override_selection(seed, "launch");
        }
        if tag_file && let Some(backend) = self.tag_backend()? {
            return self.override_selection(&backend, "tag_file");
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
        self.check_bundle_may_use(&environment)?;
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
    #[cfg(feature = "fetch")]
    pub async fn client_config(&self, selection: Selection) -> Result<Selection, String> {
        client_config::resolve(self, selection).await
    }

    /// `cloud env check-create`: the preflight the app runs before every Cloud create, on its path. The
    /// backend's client-config is read only when a field needs an advertised capability
    /// (ADVANCED_CREATE_FIELDS): a plain create (a chat's machine) needs none, so it answers with no
    /// network round trip, where the fetch cost a person's create one more round trip (up to its 5 s
    /// timeout on a slow link) before the create was sent.
    #[cfg(feature = "fetch")]
    pub async fn check_create(
        &self,
        selection: Selection,
        params: &serde_json::Value,
    ) -> Result<Selection, String> {
        if !client_config::create_needs_capabilities(params)? {
            return Ok(selection);
        }
        let selection = client_config::resolve(self, selection).await?;
        check_create_capabilities(&selection, params)?;
        Ok(selection)
    }

    /// A launch's read, with no network I/O when it can: the validated cache, else a known
    /// deployment's built-in configuration (what an unreachable or config-less backend gives
    /// anyway); only a custom origin with no cache is fetched. The app refreshes the cache after
    /// its window is up, so a changed backend config applies at the next launch.
    #[cfg(feature = "fetch")]
    pub async fn client_config_cache_first(
        &self,
        selection: Selection,
    ) -> Result<Selection, String> {
        match client_config::without_fetch(self, selection.clone()) {
            Some(selection) => Ok(selection),
            None => client_config::resolve(self, selection).await,
        }
    }

    /// The macOS app's launch read in its own process (cmux-daemon-launch-core's
    /// `cloud_environment_launch_read` op): the selection `cloud env get --cache-first` gives
    /// for this seed ([`launch_seed`]), with no network I/O and no child process. `Ok(None)`:
    /// only a fetch answers (a custom origin with no cache), which the app leaves to the CLI.
    ///
    /// CMUX-571 (goal next-launch-instant): the app spawned the bundled CLI for this and
    /// waited for it before its launch work; a fresh copy's first CLI run took 662 ms (17 ms warm).
    pub fn launch_read(&self, seed: Option<&str>) -> Result<Option<Selection>, String> {
        Ok(client_config::without_fetch(self, self.resolve(seed)?))
    }

    /// Applies a previously fetched, validated client-config cache without
    /// performing network I/O. Daemon consumers use this after CLI bootstrap.
    pub fn cached_client_config(&self, selection: Selection) -> Result<Option<Selection>, String> {
        client_config::cached(self, selection)
    }

    pub fn state_path(&self) -> PathBuf {
        bundle_folder(&self.home, &self.bundle_id).join(STATE_FILE)
    }

    pub fn bundle_id(&self) -> &str {
        &self.bundle_id
    }
    /// A local dev build (`com.cmuxterm.app.debug`, a tagged `com.cmuxterm.app.debug.<tag>`): the
    /// only bundles that read [`BACKEND_FILE`] or accept a [`Environment::Tailnet`] backend.
    pub fn dev_build(&self) -> bool {
        is_dev_bundle(&self.bundle_id)
    }

    fn override_selection(&self, value: &str, source: &str) -> Result<Selection, String> {
        let environment = Environment::parse(value)?;
        self.check_bundle_may_use(&environment)?;
        let mut selection = self.selection(environment, 0)?;
        // An explicit override must never adopt a previous default's
        // credentials or pairing, even when it spells the default backend.
        selection.legacy_storage = false;
        selection.auth_storage_namespace = Some(selection.auth_namespace.clone());
        selection.backend_override = Some(source.into());
        Ok(selection)
    }

    /// Release, RC and NIGHTLY never take a loopback origin; only a dev build takes a tailnet one.
    fn check_bundle_may_use(&self, environment: &Environment) -> Result<(), String> {
        let allowed = match environment {
            Environment::LocalOrigin(_) => self.mutable(),
            Environment::Tailnet(_) => self.dev_build(),
            _ => true,
        };
        if allowed {
            Ok(())
        } else {
            Err(format!(
                "cloud environment origin is not allowlisted for bundle {}",
                self.bundle_id
            ))
        }
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
        // Every selection, including one read back from the state file (a plain
        // file anyone can write), passes the bundle check that set() and the
        // launch overrides use: NIGHTLY never takes a tailnet backend from it.
        self.check_bundle_may_use(&environment)?;
        // These are the only historical defaults with known credential and
        // pairing destinations. Debug/tagged bundles allowed arbitrary old
        // overrides, so they cannot safely adopt unscoped previous state.
        let legacy_storage = legacy_hint.unwrap_or(revision == 0)
            && match self.bundle_id.as_str() {
                "com.cmuxterm.app.debug.next" => environment == Environment::Dev,
                // Shipped NEXT Nightly is `com.cmuxterm.app.nightly`; its session
                // was in `<bundle>.auth` before runtime selection (2026-11-05).
                "com.cmuxterm.app"
                | "com.cmuxterm.app.rc"
                | SHIPPED_NIGHTLY_BUNDLE
                | NIGHTLY_BUNDLE => environment == Environment::Prod,
                bundle if bundle.starts_with("com.cmuxterm.app.rc.") => {
                    environment == Environment::Prod
                }
                _ => false,
            };
        let mut auth_namespace = format!("{}-{revision}", namespace(&configuration.api_origin));
        // A state root's run signs in on its own: never the account's earlier, unscoped storage.
        let legacy_storage = legacy_storage && self.run.is_none();
        if let Some(run) = &self.run {
            auth_namespace = state_root::scoped_namespace(&auth_namespace, run);
        }
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
            backend_override: None,
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

#[derive(Deserialize)]
struct BackendFile {
    backend: String,
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

/// The backend a launch's arguments name (`--cloud-backend VALUE` or `--cloud-backend=VALUE`),
/// checked by [`Environment::parse`]: none when they name none, an error for a duplicate, an
/// empty or a missing value.
pub fn launch_backend(args: &[String]) -> Result<Option<String>, String> {
    let mut found = None;
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        let value = if let Some(value) = arg.strip_prefix("--cloud-backend=") {
            if value.is_empty() {
                return Err("duplicate or empty --cloud-backend".into());
            }
            value
        } else if arg == "--cloud-backend" {
            let value = args.next().ok_or("--cloud-backend requires a value")?;
            if value.is_empty() || value.starts_with('-') {
                return Err("duplicate or empty --cloud-backend".into());
            }
            value.as_str()
        } else {
            continue;
        };
        if found.is_some() {
            return Err("duplicate or empty --cloud-backend".into());
        }
        found = Some(value.to_owned());
    }
    if let Some(value) = &found {
        Environment::parse(value)?;
    }
    Ok(found)
}

/// The seed of a launch's read (`cloud env get --launch-args`): the launch arguments' backend,
/// else `CMUX_NEXT_CLOUD_BACKEND`, else `CMUX_NEXT_CLOUD_ENV` (`env` reads the variable).
pub fn launch_seed(
    args: &[String],
    env: impl Fn(&str) -> Option<String>,
) -> Result<Option<String>, String> {
    Ok(launch_backend(args)?
        .or_else(|| env("CMUX_NEXT_CLOUD_BACKEND"))
        .or_else(|| env("CMUX_NEXT_CLOUD_ENV")))
}

/// NEXT's own folder for one bundle, `~/Library/Application Support/cmux-next/<bundle id>`
/// (CmuxNext `NextSupport.bundleFolder`): the selection state, its client-config cache and the
/// app's other per-bundle Cloud and SSH state. Builds before kept these in classic cmux's
/// `cmux/<bundle id>` (cmuxterm-hq goals/next-store-out-of-classic.md), which classic cmux of the
/// same bundle id (NIGHTLY) also uses, so only NEXT's items move out of it ([`move_from_classic`]).
pub fn bundle_folder(home: &Path, bundle_id: &str) -> PathBuf {
    home.join("Library/Application Support/cmux-next").join(bundle_id)
}

/// Where builds before kept [`bundle_folder`]'s items: classic cmux's `cmux/<bundle id>`.
fn classic_bundle_folder(home: &Path, bundle_id: &str) -> PathBuf {
    home.join("Library/Application Support/cmux").join(bundle_id)
}

/// The items this crate keeps in [`bundle_folder`] that builds before kept in classic's folder.
const MOVED_ITEMS: [&str; 2] = [STATE_FILE, "client-config"];

/// Moves this crate's items from classic cmux's `cmux/<bundle id>` to [`bundle_folder`], once
/// each, and leaves a symlink at each old path for a daemon from before the move. The app moves
/// them (and its own items) at launch (CmuxNext `ClassicFolderItemsMove.moveBundleItems`); this
/// does the same for a CLI or daemon that runs first. Never over anything at the new path: an
/// item already there stays the one in use, and the old one is left where it is. A few `lstat`s
/// when there is nothing to move. Best effort: a failure leaves the old item, and the resolver
/// starts in the new place.
fn move_from_classic(home: &Path, bundle_id: &str) {
    let classic = classic_bundle_folder(home, bundle_id);
    let next = bundle_folder(home, bundle_id);
    for name in MOVED_ITEMS {
        let (old, new) = (classic.join(name), next.join(name));
        let Ok(kind) = fs::symlink_metadata(&old).map(|meta| meta.file_type()) else {
            continue;
        };
        if !(kind.is_file() || kind.is_dir()) || fs::symlink_metadata(&new).is_ok() {
            continue;
        }
        if create_private_dir(&next).is_err() {
            return;
        }
        let moved = if kind.is_dir() {
            // rename(2) of a folder never replaces one with files, nor a file.
            fs::rename(&old, &new).is_ok()
        } else {
            // A hard link is refused when anything is at `new`, which a plain rename of a file would replace.
            fs::hard_link(&old, &new).is_ok() && fs::remove_file(&old).is_ok()
        };
        if moved {
            link_back(&new, &old);
        }
    }
}

#[cfg(unix)]
fn link_back(new: &Path, old: &Path) {
    let _ = std::os::unix::fs::symlink(new, old);
}

#[cfg(not(unix))]
fn link_back(_new: &Path, _old: &Path) {}

fn create_private_dir(path: &Path) -> std::io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(path)
}

fn temp_path(parent: &Path) -> PathBuf {
    parent.join(format!(".{STATE_FILE}.{}.{}.tmp", std::process::id(), next_revision()))
}

fn is_mutable_bundle(bundle_id: &str) -> bool {
    bundle_id == NIGHTLY_BUNDLE
        || bundle_id == DEV_BUNDLE
        || bundle_id.starts_with("com.cmuxterm.app.debug.")
}

fn is_dev_bundle(bundle_id: &str) -> bool {
    bundle_id == DEV_BUNDLE || bundle_id.starts_with("com.cmuxterm.app.debug.")
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

    fn classic(home: &Home, bundle: &str) -> PathBuf {
        classic_bundle_folder(&home.0, bundle)
    }

    #[test]
    fn state_moves_out_of_classics_folder_once_and_classics_sign_in_stays() {
        let home = Home::new();
        let old = classic(&home, SHIPPED_NIGHTLY_BUNDLE);
        fs::create_dir_all(old.join("client-config")).unwrap();
        fs::write(old.join(STATE_FILE), r#"{"name":"staging","revision":7,"explicit":true}"#)
            .unwrap();
        fs::write(old.join("client-config/origin.json"), "{}").unwrap();
        // Classic NIGHTLY shares the bundle id and keeps its file-fallback sign-in here.
        fs::write(old.join("credentials.json"), "classic").unwrap();

        let resolver = Resolver::new(SHIPPED_NIGHTLY_BUNDLE, &home.0).unwrap();
        let next = bundle_folder(&home.0, SHIPPED_NIGHTLY_BUNDLE);
        assert_eq!(resolver.state_path(), next.join(STATE_FILE));
        assert!(fs::symlink_metadata(next.join(STATE_FILE)).unwrap().is_file());
        assert_eq!(fs::read_to_string(next.join("client-config/origin.json")).unwrap(), "{}");
        // An older daemon still reads the old paths, through the links left there.
        assert!(fs::symlink_metadata(old.join(STATE_FILE)).unwrap().file_type().is_symlink());
        assert!(fs::read_to_string(old.join(STATE_FILE)).unwrap().contains("staging"));
        assert_eq!(fs::read_to_string(old.join("client-config/origin.json")).unwrap(), "{}");
        assert_eq!(fs::read_to_string(old.join("credentials.json")).unwrap(), "classic");
        assert!(!next.join("credentials.json").exists());

        // Once: the links are not moved again, and a later resolver reads the same state.
        Resolver::new(SHIPPED_NIGHTLY_BUNDLE, &home.0).unwrap();
        assert!(fs::symlink_metadata(next.join(STATE_FILE)).unwrap().is_file());
    }

    #[test]
    fn state_already_in_use_in_the_new_place_is_never_replaced() {
        let home = Home::new();
        let old = classic(&home, DEV_BUNDLE);
        let next = bundle_folder(&home.0, DEV_BUNDLE);
        fs::create_dir_all(&old).unwrap();
        fs::create_dir_all(next.join("client-config")).unwrap();
        fs::write(old.join(STATE_FILE), r#"{"name":"staging","revision":7,"explicit":true}"#)
            .unwrap();
        fs::write(next.join(STATE_FILE), r#"{"name":"dev","revision":0,"explicit":false}"#)
            .unwrap();
        fs::create_dir_all(old.join("client-config")).unwrap();
        fs::write(old.join("client-config/a.json"), "old").unwrap();
        fs::write(next.join("client-config/b.json"), "new").unwrap();

        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        assert_eq!(resolver.resolve(None).unwrap().name, "dev");
        assert!(fs::symlink_metadata(old.join(STATE_FILE)).unwrap().is_file());
        assert_eq!(fs::read_to_string(old.join("client-config/a.json")).unwrap(), "old");
        assert!(!next.join("client-config/a.json").exists());
    }

    #[test]
    fn a_fresh_home_writes_nothing_in_classics_folder() {
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        resolver.resolve(None).unwrap();
        assert!(resolver.state_path().is_file());
        assert!(!classic_bundle_folder(&home.0, DEV_BUNDLE).exists());
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
    fn an_update_from_a_build_before_runtime_selection_stays_signed_in() {
        // Shipped NEXT Nightly is `com.cmuxterm.app.nightly`; its session was in
        // `<bundle>.auth` before #35284 and must still be read there (2026-11-05).
        for bundle in
            ["com.cmuxterm.app", "com.cmuxterm.app.rc", "com.cmuxterm.app.nightly", NIGHTLY_BUNDLE]
        {
            let home = Home::new();
            let selected = Resolver::new(bundle, &home.0).unwrap().resolve(None).unwrap();
            assert_eq!(selected.configuration.name, "prod", "{bundle}");
            assert!(selected.legacy_storage, "{bundle}");
            assert_eq!(selected.auth_storage_namespace, None, "{bundle}");
        }
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

    const TAILNET: &str = "https://cmux-dev-backend-1.tail137216.ts.net:3850";
    const PUBLIC_STACK: &str = "https://api.s7.wdev.cmux.dev";

    /// The tag hand-off's file (`backend.json` in the bundle's folder), as review.sh writes it.
    fn write_tag_backend(home: &Home, bundle: &str, body: &str) {
        let folder = bundle_folder(&home.0, bundle);
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("backend.json"), body).unwrap();
    }

    fn override_source(selection: &Selection) -> serde_json::Value {
        serde_json::to_value(selection).unwrap()["backend_override"].clone()
    }

    #[test]
    fn a_dev_builds_tag_file_sits_below_the_launch_override_and_above_the_picker() {
        let home = Home::new();
        let bundle = "com.cmuxterm.app.debug.cnx-tag";
        let resolver = Resolver::new(bundle, &home.0).unwrap();
        // No file: the picker's choice (default dev), no override named.
        let default = resolver.resolve(None).unwrap();
        assert_eq!(default.name, "dev");
        assert_eq!(override_source(&default), serde_json::Value::Null);
        resolver.set(Environment::Staging).unwrap();
        write_tag_backend(&home, bundle, &format!(r#"{{"backend":"{TAILNET}","tag":"cnx-tag"}}"#));
        // The tag file beats the persisted picker choice...
        let tagged = resolver.resolve(None).unwrap();
        assert_eq!(tagged.api_origin, TAILNET);
        assert_eq!(tagged.name, TAILNET);
        assert_eq!(override_source(&tagged), "tag_file");
        // ...its sign-in is its own, never the picker's or a legacy default's...
        assert!(!tagged.legacy_storage);
        assert_eq!(tagged.auth_storage_namespace.as_deref(), Some(tagged.auth_namespace.as_str()));
        // ...its other services are the shared development deployment's.
        assert_eq!(tagged.platform_origin, DEVELOPMENT_PLATFORM);
        assert_eq!(tagged.stack_project_id, DEVELOPMENT_STACK_PROJECT);
        // The launch's own override beats the file.
        let launched = resolver.resolve(Some("prod")).unwrap();
        assert_eq!(launched.name, "prod");
        assert_eq!(override_source(&launched), "launch");
        // The file never rewrites the picker's choice: removing it restores staging.
        fs::remove_file(bundle_folder(&home.0, bundle).join("backend.json")).unwrap();
        assert_eq!(resolver.resolve(None).unwrap().name, "staging");
        // A file naming the shared dev deployment selects it.
        write_tag_backend(&home, bundle, r#"{"backend":"dev"}"#);
        assert_eq!(resolver.resolve(None).unwrap().name, "dev");
        // An empty value is no override.
        write_tag_backend(&home, bundle, r#"{"backend":""}"#);
        assert_eq!(resolver.resolve(None).unwrap().name, "staging");
    }

    #[test]
    fn a_tag_file_naming_anything_else_fails_closed() {
        let home = Home::new();
        let bundle = "com.cmuxterm.app.debug.cnx-tag";
        let resolver = Resolver::new(bundle, &home.0).unwrap();
        for body in [
            r#"{"backend":"https://attacker.example"}"#,
            r#"{"backend":"http://cmux-dev-backend-1.tail137216.ts.net:3850"}"#,
            r#"{"backend":"https://ts.net"}"#,
            r#"{"backend":"https://cmux-dev-backend-1.tail137216.ts.net.attacker.example"}"#,
            r#"{"backend":"https://cmux-dev-backend-1.tail137216.ts.net/path"}"#,
            r#"{"backend":"https://user@cmux-dev-backend-1.tail137216.ts.net"}"#,
            r#"{"backend":"https://100.70.231.80"}"#,
            r#"{"backend":7}"#,
            "{bad",
        ] {
            write_tag_backend(&home, bundle, body);
            assert!(resolver.resolve(None).is_err(), "{body}");
        }
    }

    #[test]
    fn release_rc_and_nightly_ignore_the_tag_file_and_refuse_a_tailnet_backend() {
        for bundle in [
            "com.cmuxterm.app",
            "com.cmuxterm.app.rc",
            "com.cmuxterm.app.rc.test",
            SHIPPED_NIGHTLY_BUNDLE,
            NIGHTLY_BUNDLE,
        ] {
            let home = Home::new();
            write_tag_backend(&home, bundle, &format!(r#"{{"backend":"{TAILNET}"}}"#));
            let resolver = Resolver::new(bundle, &home.0).unwrap();
            let selected = resolver.resolve(None).unwrap();
            assert_eq!(selected.name, "prod", "{bundle}");
            assert_eq!(override_source(&selected), serde_json::Value::Null, "{bundle}");
            assert!(resolver.resolve(Some(TAILNET)).is_err(), "{bundle}");
            assert!(resolver.resolve(Some(PUBLIC_STACK)).is_err(), "{bundle}");
        }
        // A dev bundle takes a tag stack's public origin, as its tailnet one.
        let home = Home::new();
        let dev = Resolver::new("com.cmuxterm.app.debug.cnx-tag", &home.0).unwrap();
        assert_eq!(dev.resolve(Some(PUBLIC_STACK)).unwrap().api_origin, PUBLIC_STACK);
        // NIGHTLY's picker cannot persist one either.
        let home = Home::new();
        let nightly = Resolver::new(NIGHTLY_BUNDLE, &home.0).unwrap();
        let tailnet = Environment::parse(TAILNET).unwrap();
        assert!(nightly.set(tailnet).is_err());
    }

    #[test]
    fn nightly_refuses_a_tailnet_backend_written_into_its_state_file() {
        // The picker's set() refuses it, but the state file is a plain file: a
        // hand-written or stale one must not move NIGHTLY to a tailnet backend.
        let home = Home::new();
        let nightly = Resolver::new(NIGHTLY_BUNDLE, &home.0).unwrap();
        let state = nightly.state_path();
        std::fs::create_dir_all(state.parent().unwrap()).unwrap();
        for body in [
            format!(r#"{{"name":"{TAILNET}","revision":3,"explicit":true}}"#),
            format!(r#"{{"name":"{TAILNET}"}}"#),
        ] {
            std::fs::write(&state, &body).unwrap();
            assert!(nightly.resolve(None).is_err(), "{body}");
            assert!(nightly.resolve_persisted().is_err(), "{body}");
        }
        // A dev build may keep one there.
        let dev = Resolver::new("com.cmuxterm.app.debug.cnx-tag", &home.0).unwrap();
        let state = dev.state_path();
        std::fs::create_dir_all(state.parent().unwrap()).unwrap();
        std::fs::write(&state, format!(r#"{{"name":"{TAILNET}","revision":3,"explicit":true}}"#))
            .unwrap();
        assert_eq!(dev.resolve(None).unwrap().name, TAILNET);
    }

    #[test]
    fn the_persisted_read_never_takes_the_tag_file() {
        let home = Home::new();
        let bundle = "com.cmuxterm.app.debug.cnx-tag";
        let resolver = Resolver::new(bundle, &home.0).unwrap();
        resolver.set(Environment::Staging).unwrap();
        write_tag_backend(&home, bundle, &format!(r#"{{"backend":"{TAILNET}"}}"#));
        assert_eq!(resolver.resolve_persisted().unwrap().name, "staging");
        assert_eq!(resolver.resolve(None).unwrap().name, TAILNET);
    }

    #[test]
    fn tailnet_origins_are_https_machine_names_only() {
        for origin in [
            TAILNET,
            "https://cmux-dev-backend-1.tail137216.ts.net",
            "https://cmux-dev-backend-1.tail137216.ts.net/",
        ] {
            let parsed = Environment::parse(origin).unwrap();
            assert_eq!(parsed.configuration().api_origin, origin.trim_end_matches('/'), "{origin}");
        }
        for origin in [
            "http://cmux-dev-backend-1.tail137216.ts.net:3850",
            "https://ts.net",
            "https://tail137216.ts.net",
            "https://cmux-dev-backend-1.tail137216.ts.net.attacker.example",
            "https://cmux-dev-backend-1.tail137216.ts.net/v1",
            "https://cmux-dev-backend-1.tail137216.ts.net?x=1",
            "https://user@cmux-dev-backend-1.tail137216.ts.net",
            "https://cmux_dev.tail137216.ts.net",
            // Another tailnet's machine (a Funnel name is public) or a name under ours that is no machine.
            "https://cmux-dev-backend-1.tail9999.ts.net:3850",
            "https://evil.ts.net",
            "https://a.b.tail137216.ts.net",
            "https://.tail137216.ts.net",
            // Under cmux.dev but no tag stack's API host.
            "https://mobile.s7.wdev.cmux.dev",
            "https://api.s7.wdev.cmux.dev:8443",
            "https://api.s7.other.cmux.dev",
            "https://cmux.dev",
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

    fn words(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    /// CMUX-571: the app's launch read runs in its own process ([`Resolver::launch_read`]).
    /// A known deployment answers with no fetch, persisted like `cloud env get`.
    #[test]
    fn the_launch_read_answers_a_known_deployment_with_no_fetch() {
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        let read = resolver.launch_read(None).unwrap().expect("a known deployment needs no fetch");
        assert_eq!(read.name, "dev");
        assert_eq!(read.config_source, ConfigSource::KnownOriginFallback);
        assert_eq!(read.bundle_id, DEV_BUNDLE);
        assert!(resolver.state_path().is_file(), "the first launch's default is persisted");
        let seeded = resolver.launch_read(Some("staging")).unwrap().unwrap();
        assert_eq!(seeded.name, "staging");
        assert!(!seeded.legacy_storage, "an override never adopts the default's credentials");
    }

    /// A custom origin with no cache is left to the CLI's fetch; a refused seed is an error.
    #[test]
    fn the_launch_read_leaves_a_custom_origin_with_no_cache_to_the_fetch() {
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        assert_eq!(resolver.launch_read(Some("http://127.0.0.1:9")).unwrap(), None);
        assert!(resolver.launch_read(Some("https://example.com")).is_err());
        let release = Resolver::new("com.cmuxterm.app", &home.0).unwrap();
        assert!(release.launch_read(Some("http://127.0.0.1:9")).is_err());
    }

    /// The launch read is the CLI's `get --cache-first` minus the fetch.
    #[cfg(feature = "fetch")]
    #[test]
    fn the_launch_read_is_the_cache_first_read() {
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        for seed in [None, Some("staging"), Some("prod")] {
            let cli = runtime
                .block_on(resolver.client_config_cache_first(resolver.resolve(seed).unwrap()))
                .unwrap();
            assert_eq!(resolver.launch_read(seed).unwrap(), Some(cli), "seed {seed:?}");
        }
    }

    #[test]
    fn the_launch_seed_is_the_arguments_then_the_environment() {
        let env = |key: &str| match key {
            "CMUX_NEXT_CLOUD_BACKEND" => Some("staging-from-env".to_owned()),
            "CMUX_NEXT_CLOUD_ENV" => Some("prod".to_owned()),
            _ => None,
        };
        let backend = |args: &[&str]| launch_seed(&words(args), env);
        assert_eq!(
            backend(&["cmux", "--cloud-backend", STAGING_API]).unwrap().as_deref(),
            Some(STAGING_API)
        );
        assert_eq!(backend(&["cmux", "--cloud-backend=dev"]).unwrap().as_deref(), Some("dev"));
        assert_eq!(backend(&["cmux"]).unwrap().as_deref(), Some("staging-from-env"));
        assert_eq!(
            launch_seed(&words(&["cmux"]), |key| (key == "CMUX_NEXT_CLOUD_ENV")
                .then(|| "prod".to_owned()))
            .unwrap()
            .as_deref(),
            Some("prod")
        );
        assert_eq!(launch_seed(&words(&["cmux"]), |_| None).unwrap(), None);
        assert!(backend(&["cmux", "--cloud-backend"]).is_err());
        assert!(backend(&["cmux", "--cloud-backend=dev", "--cloud-backend", "prod"]).is_err());
        assert!(backend(&["cmux", "--cloud-backend", "https://example.com"]).is_err());
    }
}
