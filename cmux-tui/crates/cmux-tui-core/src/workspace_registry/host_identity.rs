//! A copied home mints its own ids. VMs made from one image (or a disk
//! restored onto another machine) carry the state root's `machine-id` and
//! every session registry's `registry_id` and `session_public_id`, so those
//! machines answer with one id and overwrite each other's records in every
//! store that keys on it: the app's session registrar rewrote one record
//! about 50 times a second for nine such VMs. Each of these ids is stamped
//! with a hash of the operating system's machine identity (the cmux Cloud
//! instance id, else `/etc/machine-id`; the macOS host UUID); one stamped on
//! another machine is replaced by a fresh id at the next open. An id with no stamp (written before this, or
//! on a machine with no OS identity) is kept and stamped: a machine that was
//! not copied never changes its ids. Without an OS identity (a container
//! with no machine-id) nothing is stamped or replaced.

use super::*;

/// Beside `machine-id` in the state root: the host stamp it was minted on.
pub(super) const HOST_STAMP_FILE: &str = "machine-id.host";
/// In each registry's `meta`: the host stamp its ids were minted on.
pub(super) const HOST_STAMP_META_KEY: &str = "host_stamp";

#[cfg(test)]
thread_local! {
    /// `Some(raw)` stands in for the OS machine identity on this thread
    /// (`Some(None)`: none), so a test can move a home to "another machine".
    pub(super) static TEST_OS_IDENTITY: std::cell::RefCell<Option<Option<String>>> =
        const { std::cell::RefCell::new(None) };
}

/// The current machine's stamp: a domain-separated SHA-256 of the OS
/// identity, so the raw machine id never rests in cmux state.
pub(super) fn current_host_stamp() -> Option<String> {
    #[cfg(test)]
    if let Some(raw) = TEST_OS_IDENTITY.with(|cell| cell.borrow().clone()) {
        return raw.map(|raw| stamp_of(&raw));
    }
    os_machine_identity().map(|raw| stamp_of(&raw))
}

fn stamp_of(raw: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"cmux-tui host stamp v1\0");
    hasher.update(raw.as_bytes());
    hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// On a cmux Cloud machine, the instance id cmux-host binds (written before
/// it starts the session daemon; `/etc/machine-id` is rekeyed after it, so a
/// fork's first daemon would still read the image's). Elsewhere the systemd
/// machine id.
#[cfg(target_os = "linux")]
fn os_machine_identity() -> Option<String> {
    if let Ok(value) = fs::read_to_string("/etc/cmux/daemon-instance-id") {
        let value = value.trim();
        if !value.is_empty() && value.len() <= 256 && !value.contains(char::is_whitespace) {
            return Some(format!("cmux-instance:{value}"));
        }
    }
    ["/etc/machine-id", "/var/lib/dbus/machine-id"].iter().find_map(|path| {
        let value = fs::read_to_string(path).ok()?;
        let value = value.trim();
        // systemd's first-boot placeholder and an all-zero id name no machine.
        let valid = value.len() == 32
            && value.bytes().all(|byte| byte.is_ascii_hexdigit())
            && value.bytes().any(|byte| byte != b'0');
        valid.then(|| value.to_ascii_lowercase())
    })
}

#[cfg(target_os = "macos")]
fn os_machine_identity() -> Option<String> {
    let mut uuid = [0u8; 16];
    let timeout = libc::timespec { tv_sec: 5, tv_nsec: 0 };
    // SAFETY: gethostuuid writes exactly 16 bytes into `uuid`.
    let status = unsafe { libc::gethostuuid(uuid.as_mut_ptr(), &timeout) };
    (status == 0 && uuid.iter().any(|byte| *byte != 0))
        .then(|| uuid.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn os_machine_identity() -> Option<String> {
    None
}

/// `id`, the state root's machine id, or a fresh one when it was minted on
/// another machine. The caller holds the machine identity lock.
pub(super) fn machine_id_for_this_host(
    root: &Path,
    path: &Path,
    id: MachinePublicId,
) -> anyhow::Result<MachinePublicId> {
    let Some(current) = current_host_stamp() else {
        return Ok(id);
    };
    let stamp_path = platform::normalize_filesystem_path(root.join(HOST_STAMP_FILE));
    let stored = match fs::read_to_string(&stamp_path) {
        Ok(value) => Some(value.trim().to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(error)
                .with_context(|| format!("read machine host stamp {}", stamp_path.display()));
        }
    };
    let id = match stored {
        Some(stored) if stored == current => return Ok(id),
        Some(_) => root_identity::create_machine_id(root, path, true)?,
        None => id,
    };
    // After the new id: a start cut in between sees the old stamp again and
    // mints once more, never keeps the copied id under this machine's stamp.
    root_identity::write_identity_file(root, &stamp_path, format!("{current}\n").as_bytes(), true)
        .with_context(|| format!("write machine host stamp {}", stamp_path.display()))?;
    Ok(id)
}

/// Gives a registry copied from another machine its own `registry_id` and
/// `session_public_id`. A registry with no stamp is stamped as it is.
///
/// Every stored text that names a copied id (this daemon's personal session
/// row and its follows, pins and workspace rows, the sidebar document's
/// workspace refs, `meta` itself) is rewritten to the new one. Both ids are
/// random (a UUID and 128 random bits), so a text holding one names that id
/// and nothing else. Records other stores hold under the copied id (the
/// app's, other machines') are no longer written by this machine; their
/// owners age them out as they do for a machine that went away.
pub(super) fn rehome_registry(connection: &Connection) -> anyhow::Result<()> {
    let Some(current) = current_host_stamp() else {
        return Ok(());
    };
    let stored = meta_value(connection, HOST_STAMP_META_KEY)?;
    if stored.as_deref() == Some(current.as_str()) {
        return Ok(());
    }
    if stored.is_none() {
        stamp(connection, &current)?;
        return Ok(());
    }
    // Ids that are keys of other rows change together, so foreign keys hold
    // after the transaction; they are off while it rewrites them.
    let foreign_keys: bool = connection.query_row("PRAGMA foreign_keys", [], |row| row.get(0))?;
    connection.execute_batch("PRAGMA foreign_keys=OFF;")?;
    let result = (|| -> anyhow::Result<()> {
        let tx = connection.unchecked_transaction()?;
        let renames = [
            (required_meta(&tx, "registry_id")?, try_new_uuid_v4()?),
            (
                required_meta(&tx, "session_public_id")?,
                SessionPublicId::random()?.as_str().to_string(),
            ),
        ];
        rewrite_text_everywhere(&tx, &renames)?;
        tx.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![HOST_STAMP_META_KEY, current],
        )?;
        tx.commit()?;
        Ok(())
    })();
    if foreign_keys {
        connection.execute_batch("PRAGMA foreign_keys=ON;")?;
    }
    result
}

fn stamp(connection: &Connection, current: &str) -> anyhow::Result<()> {
    connection.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![HOST_STAMP_META_KEY, current],
    )?;
    Ok(())
}

/// Replaces each `(old, new)` in every text value of every table. Runs once
/// per copied registry.
fn rewrite_text_everywhere(
    tx: &Transaction<'_>,
    renames: &[(String, String)],
) -> anyhow::Result<()> {
    let tables: Vec<String> = tx
        .prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )?
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    for table in tables {
        let columns: Vec<String> = tx
            .prepare("SELECT name FROM pragma_table_info(?1)")?
            .query_map([&table], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        for column in columns {
            let sql = format!(
                "UPDATE {table} SET {column} = replace({column}, ?1, ?2)
                 WHERE typeof({column}) = 'text' AND instr({column}, ?1) > 0",
                table = quote_identifier(&table),
                column = quote_identifier(&column),
            );
            for (old, new) in renames {
                tx.execute(&sql, params![old, new])?;
            }
        }
    }
    Ok(())
}

fn quote_identifier(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SESSION: &str = "clone-check";

    fn temp_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("cmux-host-identity-{label}-{}", new_uuid_v4()))
    }

    fn as_machine(raw: Option<&str>) {
        TEST_OS_IDENTITY.with(|cell| *cell.borrow_mut() = Some(raw.map(str::to_string)));
    }

    /// (registry id, session public id, machine id) after an open on `root`.
    fn ids(root: &Path) -> (String, String, String) {
        let registry = WorkspaceRegistry::open(root, SESSION).unwrap();
        let ids = (
            registry.registry_id().to_string(),
            registry.session_id().as_str().to_string(),
            registry.machine_id().as_str().to_string(),
        );
        drop(registry);
        ids
    }

    fn copy_tree(from: &Path, to: &Path) {
        fs::create_dir_all(to).unwrap();
        for entry in fs::read_dir(from).unwrap() {
            let entry = entry.unwrap();
            let target = to.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                copy_tree(&entry.path(), &target);
            } else {
                fs::copy(entry.path(), target).unwrap();
            }
        }
    }

    fn registry_file(root: &Path) -> PathBuf {
        persistent_session_state_dir(root, SESSION).join(WORKSPACE_REGISTRY_FILE)
    }

    /// Every text value in the registry that contains `needle`, as table.column.
    fn texts_naming(root: &Path, needle: &str) -> Vec<String> {
        let connection = Connection::open(registry_file(root)).unwrap();
        let tables: Vec<String> = connection
            .prepare(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        let mut found = Vec::new();
        for table in tables {
            let columns: Vec<String> = connection
                .prepare("SELECT name FROM pragma_table_info(?1)")
                .unwrap()
                .query_map([&table], |row| row.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect();
            for column in columns {
                let hits: i64 = connection
                    .query_row(
                        &format!(
                            "SELECT COUNT(*) FROM {} WHERE typeof({c}) = 'text' AND instr({c}, ?1) > 0",
                            quote_identifier(&table),
                            c = quote_identifier(&column),
                        ),
                        [needle],
                        |row| row.get(0),
                    )
                    .unwrap();
                if hits > 0 {
                    found.push(format!("{table}.{column}"));
                }
            }
        }
        found
    }

    fn own_session_row(root: &Path, registry_id: &str) -> bool {
        Connection::open(registry_file(root))
            .unwrap()
            .prepare("SELECT 1 FROM sessions WHERE session_id = ?1")
            .unwrap()
            .exists([registry_id])
            .unwrap()
    }

    #[test]
    fn a_home_copied_to_another_machine_mints_new_ids_and_the_same_machine_keeps_them() {
        let first = "0123456789abcdef0123456789abcdef";
        let second = "fedcba9876543210fedcba9876543210";
        let original = temp_root("original");
        as_machine(Some(first));
        let made = ids(&original);
        assert_eq!(ids(&original), made, "the same machine keeps its ids");

        // VMs made from one image: the whole state root, under another machine id.
        let clone = temp_root("clone");
        copy_tree(&original, &clone);
        as_machine(Some(second));
        let cloned = ids(&clone);
        assert_ne!(cloned.0, made.0, "registry id");
        assert_ne!(cloned.1, made.1, "session public id");
        assert_ne!(cloned.2, made.2, "machine id");
        assert!(texts_naming(&clone, &made.0).is_empty(), "{:?}", texts_naming(&clone, &made.0));
        assert!(texts_naming(&clone, &made.1).is_empty(), "{:?}", texts_naming(&clone, &made.1));
        assert!(own_session_row(&clone, &cloned.0), "the own personal session moved to the new id");
        assert_eq!(ids(&clone), cloned, "minted once: the clone keeps its new ids");

        // The machine the image was made of is untouched.
        as_machine(Some(first));
        assert_eq!(ids(&original), made);
        for root in [original, clone] {
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn ids_written_before_the_stamp_or_without_an_os_identity_are_kept() {
        let root = temp_root("unstamped");
        as_machine(None);
        let made = ids(&root);
        assert!(!root.join(HOST_STAMP_FILE).exists(), "no OS identity: nothing stamped");
        // The first open with an OS identity stamps the ids as they are.
        as_machine(Some("00000000000000000000000000000001"));
        assert_eq!(ids(&root), made);
        assert!(root.join(HOST_STAMP_FILE).exists());
        // A copy made with no OS identity on either side keeps them too.
        as_machine(None);
        assert_eq!(ids(&root), made);
        fs::remove_dir_all(root).unwrap();
    }
}
