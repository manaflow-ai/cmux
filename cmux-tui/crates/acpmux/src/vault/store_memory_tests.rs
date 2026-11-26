use super::{SecretStore, UNAVAILABLE};
use zeroize::Zeroizing;

#[derive(Default)]
pub struct MemoryStore {
    pub items: std::sync::Mutex<std::collections::BTreeMap<String, Zeroizing<String>>>,
    pub unavailable: bool,
    /// Deletes fail (a locked keychain).
    pub fail_delete: std::sync::atomic::AtomicBool,
    /// Reads fail.
    pub fail_get: std::sync::atomic::AtomicBool,
    /// Writes of this name fail.
    pub fail_put: Option<String>,
    /// Kind `memory`: stands for the daemon's memory store.
    pub memory_mode: bool,
    /// The OS store a memory-mode store cleans up (`os_leftovers`).
    pub leftovers: Option<Box<MemoryStore>>,
}

impl SecretStore for MemoryStore {
    fn kind(&self) -> &'static str {
        if self.unavailable {
            "unavailable"
        } else if self.memory_mode {
            "memory"
        } else {
            "test"
        }
    }
    fn put(&self, name: &str, value: &str) -> Result<(), &'static str> {
        if self.unavailable {
            return Err(UNAVAILABLE);
        }
        if self.fail_put.as_deref() == Some(name) {
            return Err("vault.secret_store_write_failed");
        }
        self.items.lock().unwrap().insert(name.to_owned(), Zeroizing::new(value.to_owned()));
        Ok(())
    }
    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        if self.fail_get.load(std::sync::atomic::Ordering::SeqCst) {
            return Err("vault.secret_store_read_failed");
        }
        Ok(self.items.lock().unwrap().get(name).cloned())
    }
    fn delete(&self, name: &str) -> Result<(), &'static str> {
        if self.unavailable {
            return Err(UNAVAILABLE);
        }
        if self.fail_delete.load(std::sync::atomic::Ordering::SeqCst) {
            return Err("vault.secret_store_delete_failed");
        }
        self.items.lock().unwrap().remove(name);
        Ok(())
    }
    fn os_leftovers(&self) -> Option<&dyn SecretStore> {
        self.leftovers.as_deref().map(|s| s as &dyn SecretStore)
    }
}
