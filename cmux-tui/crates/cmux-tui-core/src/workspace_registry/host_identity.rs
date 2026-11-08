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
/// Every reference to the copied id is rewritten to the new one, in any
/// column of a mutable table and in any string or key of a JSON value there:
/// the id itself (`meta`, this daemon's own personal session row and its
/// follows, pins and workspace rows, workspace refs) and the ids derived
/// from it, whole (`sec_m_<id>`, the machine's sidebar section) or as a
/// prefix (`itm_w_<id>_<workspace>` items, `<id>/<key>` placements,
/// `<id>:<workspace>` layout refs). Free text that merely contains the id (a
/// command, a path, a description) is left as it is.
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

/// `text` with a reference to `old` (see [`rehome_registry`]) moved to
/// `new`, or `None` when it is not one.
fn rehomed(text: &str, old: &str, new: &str) -> Option<String> {
    use cmux_layout_reducer::sidebar_doc::MACHINE_SECTION_PREFIX;
    if text == old {
        return Some(new.to_string());
    }
    if text.strip_prefix(MACHINE_SECTION_PREFIX) == Some(old) {
        return Some(format!("{MACHINE_SECTION_PREFIX}{new}"));
    }
    if let Some(workspace) =
        text.strip_prefix("itm_w_").and_then(|rest| rest.strip_prefix(old)?.strip_prefix('_'))
    {
        return Some(format!("itm_w_{new}_{workspace}"));
    }
    let rest = text.strip_prefix(old)?;
    (rest.starts_with('/') || rest.starts_with(':')).then(|| format!("{new}{rest}"))
}

/// Rewrites references to `old` to `new`. Runs once per copied registry.
/// Rows that key on the id and rows that refer to them change in one
/// transaction, so foreign keys are checked at its commit, not after each
/// statement.
fn rewrite_text_everywhere(tx: &Transaction<'_>, old: &str, new: &str) -> anyhow::Result<()> {
    tx.execute_batch("PRAGMA defer_foreign_keys=ON;")?;
    for (table, columns) in mutable_columns(tx)? {
        let table = quote_identifier(&table);
        for column in columns {
            let column = quote_identifier(&column);
            let texts: Vec<String> = tx
                .prepare(&format!(
                    "SELECT DISTINCT {column} FROM {table}
                     WHERE typeof({column}) = 'text' AND instr({column}, ?1) > 0"
                ))?
                .query_map([old], |row| row.get(0))?
                .collect::<Result<_, _>>()?;
            for text in texts {
                let replacement =
                    rehomed(&text, old, new).or_else(|| rehomed_json(&text, old, new));
                if let Some(replacement) = replacement {
                    tx.execute(
                        &format!("UPDATE {table} SET {column} = ?2 WHERE {column} = ?1"),
                        params![text, replacement],
                    )?;
                }
            }
        }
    }
    Ok(())
}

/// A JSON object or array `text` with its references moved, when it has any.
fn rehomed_json(text: &str, old: &str, new: &str) -> Option<String> {
    if !text.starts_with(['{', '[']) {
        return None;
    }
    let mut value = serde_json::from_str::<Value>(text).ok()?;
    rehome_value(&mut value, old, new).then(|| value.to_string())
}

fn rehome_value(value: &mut Value, old: &str, new: &str) -> bool {
    match value {
        Value::String(text) => match rehomed(text, old, new) {
            Some(replacement) => {
                *text = replacement;
                true
            }
            None => false,
        },
        Value::Object(map) => {
            let mut changed = false;
            let keys: Vec<String> = map.keys().cloned().collect();
            for key in keys {
                if let Some(renamed) = rehomed(&key, old, new)
                    && let Some(child) = map.remove(&key)
                {
                    map.insert(renamed, child);
                    changed = true;
                }
            }
            for child in map.values_mut() {
                changed |= rehome_value(child, old, new);
            }
            changed
        }
        Value::Array(items) => {
            items.iter_mut().fold(false, |changed, item| rehome_value(item, old, new) | changed)
        }
        _ => false,
    }
}

fn quote_identifier(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SESSION: &str = "clone-check";
    /// Columns that hold a session id as their whole value.
    const SESSION_ID_COLUMNS: [&str; 2] = ["session_id", "default_session_id"];
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

    /// Every session-id column (whole value) of a mutable table that holds
    /// `needle`, as table.column.
    fn session_columns_naming(root: &Path, needle: &str) -> Vec<String> {
        let connection = Connection::open(registry_file(root)).unwrap();
        let mut found = Vec::new();
        for (table, columns) in mutable_columns(&connection).unwrap() {
            for column in columns.iter().filter(|c| SESSION_ID_COLUMNS.contains(&c.as_str())) {
                let hits: i64 = connection
                    .query_row(
                        &format!(
                            "SELECT COUNT(*) FROM {} WHERE {} = ?1",
                            quote_identifier(&table),
                            quote_identifier(column),
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

    /// Free text that holds the id (a command, a path) and a JSON record that
    /// names the session, as user data and a reference would.
    fn plant(root: &Path, id: &str) {
        Connection::open(registry_file(root))
            .unwrap()
            .execute_batch(&format!(
                "CREATE TABLE user_text(command TEXT, record_json TEXT);
                 INSERT INTO user_text VALUES('cd /srv/{id} && ls',
                   '{{\"command\":\"echo {id}\",\"ref\":{{\"session_id\":\"{id}\"}}}}');"
            ))
            .unwrap();
    }

    fn planted(root: &Path) -> (String, Value) {
        Connection::open(registry_file(root))
            .unwrap()
            .query_row("SELECT command, record_json FROM user_text", [], |row| {
                Ok((row.get(0)?, serde_json::from_str(&row.get::<_, String>(1)?).unwrap()))
            })
            .unwrap()
    }

    /// A customised sidebar on `session`'s machine section: renamed, with a
    /// group holding the workspace's item. Returns the group's id.
    fn customize_sidebar(root: &Path, session: &str) -> String {
        use cmux_layout_reducer::sidebar_doc::{
            Body, NewItem, Op, Patch, SectionPatch, Target, WorkspaceRef, machine_section_id,
            reduce,
        };
        let connection = Connection::open(registry_file(root)).unwrap();
        let tx = connection.unchecked_transaction().unwrap();
        let section = machine_section_id(session);
        let workspace: String = tx
            .query_row(
                "SELECT public_id FROM resource_workspaces WHERE workspace_key = 'one'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let group = "itm_custom_group".to_string();
        crate::state::sidebar_doc_store::with_doc_mut(&tx, |doc| {
            assert!(doc.section(&section).is_some(), "the machine section exists");
            let placed = doc.items_unordered().find_map(|item| match &item.body {
                Body::Workspace { reference } if reference.session_id == session => {
                    Some(item.id.clone())
                }
                _ => None,
            });
            let mut ops = Vec::new();
            let item = placed.unwrap_or_else(|| {
                let id = format!("itm_w_{session}_{workspace}");
                ops.push(Op::ItemAdd {
                    item: NewItem {
                        id: Some(id.clone()),
                        body: Body::Workspace { reference: WorkspaceRef::new(session, &workspace) },
                        shows_label: true,
                        span: None,
                        extra: Default::default(),
                    },
                    to: Target::end(&section),
                });
                id
            });
            ops.push(Op::SectionUpdate {
                id: section.clone(),
                patch: SectionPatch { title: Patch::Set("Renamed".into()), ..Default::default() },
            });
            ops.push(Op::GroupCreate {
                id: Some(group.clone()),
                name: "Custom".into(),
                color: None,
                icon: None,
                profile: None,
                items: vec![item],
                to: Some(Target::end(&section)),
            });
            let previous = doc.revision;
            let applied = reduce::apply_in_place(
                doc,
                &ops,
                &mut crate::state::sidebar_doc_legacy::mint_item_id,
            )
            .map_err(|refusal| anyhow::anyhow!("{}", refusal.as_str()))?;
            crate::state::sidebar_doc_store::write_changes(
                &tx,
                previous,
                doc.revision,
                &applied.changes,
                None,
            )?;
            Ok(())
        })
        .unwrap();
        tx.commit().unwrap();
        group
    }

    /// The machine section of `session` after an open: (title, the group's
    /// section, the sessions of the workspaces under the group).
    fn sidebar_of(
        root: &Path,
        session: &str,
        group: &str,
    ) -> (Option<String>, String, Vec<String>) {
        use cmux_layout_reducer::sidebar_doc::machine_section_id;
        drop(WorkspaceRegistry::open(root, SESSION).unwrap());
        let connection = Connection::open(registry_file(root)).unwrap();
        crate::state::sidebar_doc_store::with_doc(&connection, |doc| {
            let section = doc
                .section(&machine_section_id(session))
                .unwrap_or_else(|| panic!("no machine section for {session}"));
            let group_item = doc
                .items_unordered()
                .find(|item| item.id == group)
                .unwrap_or_else(|| panic!("group {group} is gone"));
            let members = doc
                .items_unordered()
                .filter(|item| item.parent.as_deref() == Some(group))
                .filter_map(|item| item.body.workspace().map(|r| r.session_id.clone()))
                .collect();
            Ok((section.title.clone(), group_item.section.clone(), members))
        })
        .unwrap()
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
        plant(&original, &made.0);
        let group = customize_sidebar(&original, &made.0);
        let (title, _, members) = sidebar_of(&original, &made.0, &group);
        assert_eq!(title.as_deref(), Some("Renamed"));
        assert_eq!(members.len(), 1, "the group holds the workspace");
        assert_eq!(ids(&original), made, "the same machine keeps its ids");

        // VMs made from one image: the whole state root, under another machine id.
        let clone = temp_root("clone");
        copy_tree(&original, &clone);
        as_machine(Some(second));
        let cloned = ids(&clone);
        assert_ne!(cloned.0, made.0, "registry id");
        assert_eq!(cloned.1, made.1, "the session public id stays: the journal records it");
        assert_ne!(cloned.2, made.2, "machine id");
        let stale = session_columns_naming(&clone, &made.0);
        assert!(stale.is_empty(), "session columns still name the copied id: {stale:?}");
        let (command, record) = planted(&clone);
        assert_eq!(command, format!("cd /srv/{} && ls", made.0), "free text is kept");
        assert_eq!(record["command"], format!("echo {}", made.0), "free text in JSON is kept");
        assert_eq!(record["ref"]["session_id"], cloned.0, "a JSON session ref moves");
        // The customised sidebar survives the rehome and the open's repair.
        let (title, group_section, members) = sidebar_of(&clone, &cloned.0, &group);
        assert_eq!(title.as_deref(), Some("Renamed"), "the section keeps its name");
        assert_eq!(
            group_section,
            cmux_layout_reducer::sidebar_doc::machine_section_id(&cloned.0),
            "the group stays in the machine section"
        );
        assert_eq!(members, vec![cloned.0.clone()], "the placement moves with the session");
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
