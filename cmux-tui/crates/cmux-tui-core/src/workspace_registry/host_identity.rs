//! A copied home mints its own ids. VMs made from one image (or a disk
//! restored onto another machine) carry the state root's `machine-id` and
//! every session registry's `registry_id`, so those machines answer with one
//! id and overwrite each other's records in every store that keys on it: the
//! app's session registrar rewrote one record about 50 times a second for
//! nine such VMs. Both ids are stamped with a hash of the operating system's
//! machine identity (the cmux Cloud instance id, else `/etc/machine-id`; the
//! macOS host UUID); one stamped on another machine is replaced by a fresh id
//! at the next open. An id with no stamp (written before this, or on a
//! machine with no OS identity) is kept and stamped: a machine that was not
//! copied never changes its ids. Without an OS identity (a container with no
//! machine-id) nothing is stamped or replaced.

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

/// Gives a registry copied from another machine its own `registry_id`, the
/// id other stores key this machine's session on. A registry with no stamp
/// is stamped as it is.
///
/// Every mutable text that names the copied id (`meta`, this daemon's own
/// personal session row and its follows, pins and workspace rows, the
/// sidebar document's workspace refs) is rewritten to the new one. The id is
/// a random UUID, so a text holding it names that id and nothing else.
/// Append-only history (tables whose triggers refuse an update: the session
/// journal, journal segments) keeps what it recorded. `session_public_id`
/// stays: the journal records it, and it names the session only within this
/// daemon's resource API. Records other stores hold under the copied id (the
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
    let tx = connection.unchecked_transaction()?;
    if stored.is_some() {
        let copied = required_meta(&tx, "registry_id")?;
        rewrite_text_everywhere(&tx, &copied, &try_new_uuid_v4()?)?;
    }
    stamp(&tx, &current)?;
    tx.commit()?;
    Ok(())
}

fn stamp(connection: &Connection, current: &str) -> anyhow::Result<()> {
    connection.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![HOST_STAMP_META_KEY, current],
    )?;
    Ok(())
}

/// Tables whose triggers refuse an update: append-only history.
fn immutable_tables(connection: &Connection) -> anyhow::Result<HashSet<String>> {
    Ok(connection
        .prepare(
            "SELECT tbl_name FROM sqlite_master WHERE type = 'trigger'
             AND upper(sql) LIKE '%BEFORE UPDATE%' AND upper(sql) LIKE '%RAISE(%'",
        )?
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?)
}

/// Every mutable table and its columns.
fn mutable_columns(connection: &Connection) -> anyhow::Result<Vec<(String, Vec<String>)>> {
    let immutable = immutable_tables(connection)?;
    let tables: Vec<String> = connection
        .prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )?
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let mut out = Vec::new();
    for table in tables.into_iter().filter(|table| !immutable.contains(table)) {
        let columns: Vec<String> = connection
            .prepare("SELECT name FROM pragma_table_info(?1)")?
            .query_map([&table], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        out.push((table, columns));
    }
    Ok(out)
}

/// Replaces `old` with `new` in every text value of every mutable table.
/// Runs once per copied registry. Rows that key on the id and rows that
/// refer to them change in one transaction, so foreign keys are checked at
/// its commit, not after each statement.
fn rewrite_text_everywhere(tx: &Transaction<'_>, old: &str, new: &str) -> anyhow::Result<()> {
    tx.execute_batch("PRAGMA defer_foreign_keys=ON;")?;
    for (table, columns) in mutable_columns(tx)? {
        for column in columns {
            tx.execute(
                &format!(
                    "UPDATE {table} SET {column} = replace({column}, ?1, ?2)
                     WHERE typeof({column}) = 'text' AND instr({column}, ?1) > 0",
                    table = quote_identifier(&table),
                    column = quote_identifier(&column),
                ),
                params![old, new],
            )?;
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
    const TERMINAL: &str = "00000000000040008000000000000001";

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

    /// Every mutable text value in the registry that contains `needle`, as
    /// table.column (append-only history keeps what it recorded).
    fn texts_naming(root: &Path, needle: &str) -> Vec<String> {
        let connection = Connection::open(registry_file(root)).unwrap();
        let mut found = Vec::new();
        for (table, columns) in mutable_columns(&connection).unwrap() {
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

    /// A registry in use: a workspace and a terminal, so the session journal
    /// and its append-only triggers hold rows naming the session.
    fn seed(root: &Path) {
        let mut registry = WorkspaceRegistry::open(root, SESSION).unwrap();
        super::super::tests::seed_workspace(&mut registry, "one");
        super::super::tests::reserve_terminal(&mut registry, TERMINAL, 0);
        drop(registry);
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
    fn a_home_copied_to_another_machine_mints_new_registry_and_machine_ids_and_the_same_machine_keeps_them()
     {
        let first = "0123456789abcdef0123456789abcdef";
        let second = "fedcba9876543210fedcba9876543210";
        let original = temp_root("original");
        as_machine(Some(first));
        seed(&original);
        let made = ids(&original);
        assert_eq!(ids(&original), made, "the same machine keeps its ids");

        // VMs made from one image: the whole state root, under another machine id.
        let clone = temp_root("clone");
        copy_tree(&original, &clone);
        as_machine(Some(second));
        let cloned = ids(&clone);
        assert_ne!(cloned.0, made.0, "registry id");
        assert_eq!(cloned.1, made.1, "the session public id stays: the journal records it");
        assert_ne!(cloned.2, made.2, "machine id");
        assert!(texts_naming(&clone, &made.0).is_empty(), "{:?}", texts_naming(&clone, &made.0));
        let reopened = WorkspaceRegistry::open(&clone, SESSION).unwrap();
        assert_eq!(reopened.snapshot().unwrap().workspaces[0].key, "one", "the workspaces stay");
        drop(reopened);
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
