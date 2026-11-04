//! Runtime NEXT Cloud environment selection.
//!
//! This crate is deliberately independent of the app shell.  It owns the one
//! endpoint table used by the CLI, daemon and Swift bridge, and persists only
//! the selected environment name and sign-in revision. Secrets (Stack tokens) remain in the
//! environment-specific Keychain namespace owned by the app.

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
    Dev,
    Preview(u32),
    Staging,
    Prod,
}

impl Environment {
    pub fn parse(value: &str) -> Result<Self, String> {
        let value = value.trim();
        match value.to_ascii_lowercase().as_str() {
            "local" => Ok(Self::Local),
            "dev" | "development" => Ok(Self::Dev),
            "staging" => Ok(Self::Staging),
            "prod" | "production" => Ok(Self::Prod),
            _ => {
                let Some(number) = value.strip_prefix("preview-") else {
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

    pub fn name(&self) -> String {
        match self {
            Self::Local => "local".into(),
            Self::Dev => "dev".into(),
            Self::Preview(number) => format!("preview-{number}"),
            Self::Staging => "staging".into(),
            Self::Prod => "prod".into(),
        }
    }

    pub fn configuration(&self) -> Configuration {
        let deployment = match self {
            Self::Local => LOCAL_DEPLOYMENT,
            Self::Dev | Self::Preview(_) => DEVELOPMENT_DEPLOYMENT,
            Self::Staging => STAGING_DEPLOYMENT,
            Self::Prod => PRODUCTION_DEPLOYMENT,
        };
        let api_origin = match self {
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
    pub state_path: String,
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
        // Release/RC bundles are permanently production. Do not let a stale,
        // malformed, or hand-written state file redirect credentials.
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
            return self
                .selection(Environment::parse(&persisted.name)?, persisted.revision.unwrap_or(0));
        }
        let environment =
            seed.map(Environment::parse).transpose()?.unwrap_or_else(|| self.default_environment());
        let revision = next_revision();
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
                self.selection(Environment::parse(&winner.name)?, winner.revision.unwrap_or(0))
            }
            Err(error) => Err(error),
        }
    }

    pub fn set(&self, environment: Environment) -> Result<Selection, String> {
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
                    return self.selection(environment, current.revision.unwrap_or(0));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("read {}: {error}", path.display())),
        }
        let revision = next_revision();
        self.persist_replace(&environment, revision)?;
        self.selection(environment, revision)
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
        if self.bundle_id == NIGHTLY_BUNDLE { Environment::Prod } else { Environment::Dev }
    }

    fn selection(&self, environment: Environment, revision: u64) -> Result<Selection, String> {
        if !self.mutable() && environment != Environment::Prod {
            return Err(format!(
                "non-production environment is not allowed for bundle {}",
                self.bundle_id
            ));
        }
        Ok(Selection {
            auth_namespace: format!("{}-{revision}", environment.name()),
            configuration: environment.configuration(),
            bundle_id: self.bundle_id.clone(),
            mutable: self.mutable(),
            state_path: self.state_path().display().to_string(),
        })
    }

    fn persist_new(&self, environment: &Environment, revision: u64) -> Result<(), String> {
        let path = self.state_path();
        let parent =
            path.parent().ok_or_else(|| "cloud environment state has no parent".to_string())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("create {}: {error}", parent.display()))?;
        let tmp = temp_path(parent);
        let body =
            serde_json::to_vec(&Persisted { name: environment.name(), revision: Some(revision) })
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
        let body =
            serde_json::to_vec(&Persisted { name: environment.name(), revision: Some(revision) })
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
}

static REVISION: AtomicU64 = AtomicU64::new(1);

fn next_revision() -> u64 {
    let clock =
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0);
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

    struct Home(PathBuf);
    impl Home {
        fn new() -> Self {
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
    fn mutable_resolver_seeds_once_and_reads_back() {
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        assert_eq!(resolver.resolve(Some("staging")).unwrap().name, "staging");
        assert_eq!(resolver.resolve(Some("prod")).unwrap().name, "staging");
    }

    #[test]
    fn release_cannot_be_redirected() {
        let home = Home::new();
        let resolver = Resolver::new("com.cmuxterm.app", &home.0).unwrap();
        assert_eq!(resolver.resolve(Some("dev")).unwrap().name, "prod");
        assert!(resolver.set(Environment::Dev).is_err());
    }

    #[test]
    fn real_switch_rotates_sign_in_namespace_but_same_selection_does_not() {
        let home = Home::new();
        let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
        let initial = resolver.resolve(None).unwrap();
        assert_eq!(initial.name, "dev");
        assert_eq!(resolver.set(Environment::Dev).unwrap().auth_namespace, initial.auth_namespace);
        let staging = resolver.set(Environment::Staging).unwrap();
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
        assert!(resolver.resolve(Some("prod")).is_err());
        assert_eq!(resolver.set(Environment::Prod).unwrap().name, "prod");
        assert_eq!(resolver.resolve(None).unwrap().name, "prod");
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
