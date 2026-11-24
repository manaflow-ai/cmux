//! Subscription grants use the daemon's existing vault. Per-provider indexes contain metadata
//! only. The existing ChatGPT record format remains readable during migration.

use std::path::{Path, PathBuf};

use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use uuid::Uuid;

#[cfg(any(target_os = "macos", test))]
#[derive(Default)]
enum KeychainProbe {
    #[default]
    Unchecked,
    RetryAt(std::time::Instant),
    Available,
}

#[cfg(any(target_os = "macos", test))]
impl KeychainProbe {
    fn available(&mut self, now: std::time::Instant, probe: impl FnOnce() -> bool) -> bool {
        match self {
            Self::Available => return true,
            Self::RetryAt(deadline) if now < *deadline => return false,
            _ => {}
        }
        let available = probe();
        *self = if available {
            Self::Available
        } else {
            Self::RetryAt(std::time::Instant::now().max(now) + std::time::Duration::from_secs(1))
        };
        available
    }
}

#[cfg(not(test))]
struct Vault;

#[cfg(not(test))]
impl Vault {
    fn store() -> Result<std::sync::Arc<dyn crate::vault::store::SecretStore>, Error> {
        use crate::vault::store;
        #[cfg(target_os = "macos")]
        {
            static PROBE: std::sync::Mutex<KeychainProbe> =
                std::sync::Mutex::new(KeychainProbe::Unchecked);
            let mut state = PROBE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if !state.available(std::time::Instant::now(), || {
                store::probe_as(&store::OsStore, &format!("{}.subscription", store::probe_name()))
            }) {
                return Err(Error::KeychainLocked);
            }
            Ok(std::sync::Arc::new(store::OsStore))
        }
        #[cfg(not(target_os = "macos"))]
        Ok(store::for_daemon())
    }
}

#[cfg(not(test))]
impl Keychain for Vault {
    fn read(&self, scope: &str, account: &str) -> Result<Option<Vec<u8>>, Error> {
        Self::store()?
            .get(&format!(".subscription/{scope}/{account}"))
            .map(|value| value.map(|value| value.as_bytes().to_vec()))
            .map_err(|_| Error::KeychainLocked)
    }

    fn write(&self, scope: &str, account: &str, value: &[u8]) -> Result<bool, Error> {
        let name = format!(".subscription/{scope}/{account}");
        let store = Self::store()?;
        let created = store.get(&name).map_err(|_| Error::KeychainLocked)?.is_none();
        let value = std::str::from_utf8(value).map_err(|_| Error::Storage)?;
        store.put(&name, value).map_err(|_| Error::KeychainLocked)?;
        Ok(created)
    }

    fn delete(&self, scope: &str, account: &str) -> Result<(), Error> {
        Self::store()?
            .delete(&format!(".subscription/{scope}/{account}"))
            .map_err(|_| Error::KeychainLocked)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    Storage,
    KeychainLocked,
    KeychainOtherBuild,
}

impl Error {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Storage => "storage",
            Self::KeychainLocked => "keychain_locked",
            Self::KeychainOtherBuild => "keychain_other_build",
        }
    }

    pub(crate) fn message(self) -> &'static str {
        match self {
            Self::KeychainOtherBuild => {
                "This sign-in was saved by another cmux build. Sign in again to use it here."
            }
            _ => self.code(),
        }
    }
}

pub(super) trait Keychain: Sync {
    fn read(&self, service: &str, account: &str) -> Result<Option<Vec<u8>>, Error>;
    /// True if the write created a new item.
    fn write(&self, service: &str, account: &str, value: &[u8]) -> Result<bool, Error>;
    fn delete(&self, service: &str, account: &str) -> Result<(), Error>;
}

pub(crate) struct Store<'a> {
    home: &'a Path,
    provider: &'static str,
    keychain: Option<&'a dyn Keychain>,
}

pub(crate) fn migrate_legacy(home: &Path) {
    crate::chatgpt::store::migrate_all(home);
    crate::subscriptions::migrate_all(home);
}

impl<'a> Store<'a> {
    pub(crate) fn new(home: &'a Path, provider: &'static str) -> Self {
        #[cfg(test)]
        let keychain: Option<&dyn Keychain> = Some(&tests::KEYCHAIN);
        #[cfg(not(test))]
        let keychain: Option<&dyn Keychain> =
            if cfg!(target_os = "macos") || provider != "chatgpt" { Some(&Vault) } else { None };
        Self { home, provider, keychain }
    }

    pub(crate) fn directory(&self) -> PathBuf {
        self.home.join(self.provider)
    }

    pub(super) fn path(&self, id: &str) -> Result<PathBuf, Error> {
        if !crate::routes::is_route_id(id) || id == "host" {
            return Err(Error::Storage);
        }
        Ok(self.directory().join(format!("{id}.json")))
    }

    fn service(&self) -> String {
        crate::vault::store::home_id(self.home)
    }

    fn other_provider_has_record(&self, id: &str) -> Result<bool, Error> {
        // Old Keychain accounts were named only by route id. An orphan file can
        // share that id with another provider's active or legacy record.
        let filename = format!("{id}.json");
        for provider in ["chatgpt", "grok", "copilot", "kimi"] {
            if provider != self.provider
                && self
                    .home
                    .join(provider)
                    .join(&filename)
                    .try_exists()
                    .map_err(|_| Error::Storage)?
            {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Migrate records even if there is no route pointing at them. Call on a blocking worker.
    pub(crate) fn migrate_all<T: DeserializeOwned>(&self) {
        if self.keychain.is_none() {
            return;
        }
        let Ok(entries) = std::fs::read_dir(self.directory()) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "json")
                && let Some(id) = path.file_stem().and_then(|stem| stem.to_str())
                && self.path(id).is_ok()
                && entry.file_type().is_ok_and(|kind| kind.is_file())
                && let Ok(Some(bytes)) = file(&path)
                && decode::<Value>(&bytes).is_ok_and(|record| record.get("keychain").is_none())
            {
                // read takes the store lock and rechecks the file before migrating.
                let _ = self.read::<T>(id);
            }
        }
    }

    pub(crate) fn available<T: DeserializeOwned>(&self, id: &str) -> Result<bool, Error> {
        if self.keychain.is_none() {
            return Ok(true);
        }
        self.read::<T>(id).map(|record| record.is_some())
    }

    pub(crate) fn metadata(&self, id: &str) -> Option<Value> {
        let bytes = file(&self.path(id).ok()?).ok()??;
        let record: Value = serde_json::from_slice(&bytes).ok()?;
        Some(metadata(self.provider, id, &record))
    }

    /// Call on a blocking worker. Serializes migration with writes and deletes.
    pub(crate) fn read<T: DeserializeOwned>(&self, id: &str) -> Result<Option<T>, Error> {
        let _guard = self.lock()?;
        self.read_locked(id)
    }

    fn read_locked<T: DeserializeOwned>(&self, id: &str) -> Result<Option<T>, Error> {
        let path = self.path(id)?;
        let Some(bytes) = file(&path)? else { return Ok(None) };
        let Some(keychain) = self.keychain else { return decode(&bytes).map(Some) };
        let index: Value = decode(&bytes)?;
        let service = self.service();
        if index.get("keychain").is_some() {
            let generation = generation(&index)?;
            let value = keychain.read(&service, &account(id, generation))?;
            if value.is_none() && index["signed_in"] == true {
                let mut index = index;
                index["signed_in"] = json!(false);
                let _ = self.write_index(id, &service, generation, &index);
            }
            return value.as_deref().map(decode).transpose();
        }
        let record = decode(&bytes)?;
        let generation = if self.other_provider_has_record(id)? {
            Some(Uuid::new_v4())
        } else {
            match keychain.read(&service, id) {
                // A previous migration may have written the item before the index rename.
                Ok(Some(value)) => {
                    let current: Value = decode(&value)?;
                    if legacy_item_provider(&current) != Some(self.provider) {
                        // A refused delete can leave a bare account after its index is gone.
                        Some(Uuid::new_v4())
                    } else if index["expires_at"].as_i64() <= current["expires_at"].as_i64() {
                        let stored = decode(&value)?;
                        self.write_index(id, &service, None, &current)?;
                        let parent = path.parent().ok_or(Error::Storage)?;
                        crate::home_fs::sync_dir(parent).map_err(|_| Error::Storage)?;
                        return Ok(Some(stored));
                    } else {
                        None
                    }
                }
                Err(Error::KeychainOtherBuild) => Some(Uuid::new_v4()),
                Err(error) => return Err(error),
                Ok(None) => None,
            }
        };
        self.write_keychain(keychain, id, generation, &index)?;
        Ok(Some(record))
    }

    /// Call on a blocking worker. Keychain updates preserve the existing item's access list.
    pub(crate) fn write<T: Serialize>(&self, id: &str, record: &T) -> Result<(), Error> {
        let path = self.path(id)?;
        let _guard = self.lock()?;
        if let Some(keychain) = self.keychain {
            let value = serde_json::to_value(record).map_err(|_| Error::Storage)?;
            let generation = match file(&path)? {
                Some(bytes) => match decode::<Value>(&bytes) {
                    Ok(index) if index.get("keychain").is_some() => {
                        generation(&index).unwrap_or_else(|_| Some(Uuid::new_v4()))
                    }
                    Ok(_) if !self.other_provider_has_record(id)? => None,
                    _ => Some(Uuid::new_v4()),
                },
                None => self.other_provider_has_record(id)?.then(Uuid::new_v4),
            };
            return self.write_keychain(keychain, id, generation, &value);
        }
        let bytes = serde_json::to_vec(record).map_err(|_| Error::Storage)?;
        crate::chatgpt::store::write_atomic(&path, &bytes).map_err(|_| Error::Storage)
    }

    fn write_keychain(
        &self,
        keychain: &dyn Keychain,
        id: &str,
        mut generation: Option<Uuid>,
        record: &Value,
    ) -> Result<(), Error> {
        let path = self.path(id)?;
        let service = self.service();
        let bytes = serde_json::to_vec(record).map_err(|_| Error::Storage)?;
        let mut name = account(id, generation);
        let created = match keychain.write(&service, &name, &bytes) {
            Err(Error::KeychainOtherBuild) => {
                generation = Some(Uuid::new_v4());
                name = account(id, generation);
                keychain.write(&service, &name, &bytes)?
            }
            result => result?,
        };
        if let Err(error) = self.write_index(id, &service, generation, record) {
            if created {
                let _ = keychain.delete(&service, &name);
            }
            return Err(error);
        }
        let parent = path.parent().ok_or(Error::Storage)?;
        crate::home_fs::sync_dir(parent).map_err(|_| Error::Storage)
    }

    fn write_index(
        &self,
        id: &str,
        service: &str,
        generation: Option<Uuid>,
        record: &Value,
    ) -> Result<(), Error> {
        let mut index = metadata(self.provider, id, record);
        let account = account(id, generation);
        index["keychain"] = json!(format!("keychain:cmux-vault/.subscription/{service}/{account}"));
        if let Some(generation) = generation {
            index["keychain_generation"] = json!(generation.to_string());
        }
        let bytes = serde_json::to_vec(&index).map_err(|_| Error::Storage)?;
        crate::chatgpt::store::write_atomic(&self.path(id)?, &bytes).map_err(|_| Error::Storage)
    }

    /// Call on a blocking worker. Keychain deletion is best effort.
    pub(crate) fn delete(&self, id: &str) -> Result<(), Error> {
        let _guard = self.lock()?;
        self.delete_locked(id)
    }

    pub(crate) fn delete_if<T: DeserializeOwned>(
        &self,
        id: &str,
        matches: impl FnOnce(T) -> bool,
    ) -> Result<bool, Error> {
        let _guard = self.lock()?;
        if self.read_locked(id)?.is_some_and(matches) {
            self.delete_locked(id)?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn delete_locked(&self, id: &str) -> Result<(), Error> {
        let path = self.path(id)?;
        if let Some(keychain) = self.keychain {
            let index = file(&path).ok().flatten().and_then(|bytes| decode::<Value>(&bytes).ok());
            if let Some(index) = index
                && index.get("keychain").is_some()
                && let Ok(generation) = generation(&index)
            {
                let _ = keychain.delete(&self.service(), &account(id, generation));
            }
        }
        match crate::home_fs::remove_file(path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(Error::Storage),
            _ => Ok(()),
        }
    }

    fn lock(&self) -> Result<Option<cmux_file_lock::FileLock>, Error> {
        if self.keychain.is_none() {
            return Ok(None);
        }
        // A standalone harness check can migrate a grant while the daemon is
        // using the same home. Serialize the Keychain and index transaction.
        crate::home_fs::private_dir(self.home).map_err(|_| Error::Storage)?;
        let file = crate::home_fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.home.join(".subscription-store.lock"))
            .map_err(|_| Error::Storage)?;
        cmux_file_lock::FileLock::take(file, cmux_file_lock::Kind::Exclusive)
            .map(Some)
            .map_err(|_| Error::Storage)
    }
}

fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, Error> {
    serde_json::from_slice(bytes).map_err(|_| Error::Storage)
}

fn file(path: &Path) -> Result<Option<Vec<u8>>, Error> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(Error::Storage),
    }
}

fn metadata(provider: &str, id: &str, record: &Value) -> Value {
    let mut out = json!({"route_id": id, "provider": provider});
    for key in ["client_id", "sub", "email", "login", "plan", "label", "expires_at", "region"] {
        if let Some(value) = record.get(key) {
            out[key] = value.clone();
        }
    }
    let token_field = if provider == "chatgpt" { "refresh_token" } else { "access_token" };
    out["signed_in"] = json!(record["signed_in"].as_bool().unwrap_or_else(|| {
        record[token_field].as_str().is_some_and(|token| !token.is_empty())
    }));
    out
}

fn generation(index: &Value) -> Result<Option<Uuid>, Error> {
    index
        .get("keychain_generation")
        .map(|value| {
            value.as_str().and_then(|value| Uuid::parse_str(value).ok()).ok_or(Error::Storage)
        })
        .transpose()
}

fn account(id: &str, generation: Option<Uuid>) -> String {
    generation.map_or_else(|| id.to_owned(), |generation| format!("{id}.{generation}"))
}

fn legacy_item_provider(record: &Value) -> Option<&'static str> {
    if record["client_id"].is_string() {
        Some("chatgpt")
    } else if matches!(record["region"].as_str(), Some("global" | "china")) {
        Some("kimi")
    } else if record["expires_at"] == 0 && record["refresh_token"] == "" {
        Some("copilot")
    } else if record["expires_at"].as_i64().is_some_and(|expiry| expiry > 0)
        && record["refresh_token"].as_str().is_some_and(|token| !token.is_empty())
    {
        Some("grok")
    } else {
        None
    }
}

#[cfg(test)]
mod tests;
