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
//! copied never changes its ids, except on a cmux Cloud machine whose
//! instance id was bound after the id's file was made (below). Without an OS
//! identity (a container with no machine-id) nothing is stamped or replaced.
//!
//! The Freestyle lane template (snapshot of 2026-10-30) was made before the
//! stamp existed, so its registry had none. A VM forked from it kept the
//! template's registry id and stamped it as its own: twelve lane VMs answered
//! with one id, and the app's put of each one's record under it wrote 5.57
//! million `personal.session.put` rows in two days (2026-11-02/03). The cmux
//! Cloud supervisor (`cmux-devbox-boot`) writes the instance id to
//! `/etc/cmux/daemon-instance-id` only when it changes, before it starts the
//! session daemon; a file made before that write was made on another
//! instance.

use std::time::SystemTime;

use cmux_tui_platform::file_birth;

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
    /// When this machine's instance id was bound, for
    /// [`made_before_binding`]; `None` (the default): never.
    pub(super) static TEST_IDENTITY_BOUND_AT: std::cell::RefCell<Option<SystemTime>> =
        const { std::cell::RefCell::new(None) };
}

/// The cmux Cloud supervisor's record of the instance this machine's daemon
/// is bound to.
#[cfg(target_os = "linux")]
const CLOUD_INSTANCE_FILE: &str = "/etc/cmux/daemon-instance-id";

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
    if let Some(value) = cloud_instance_id() {
        return Some(format!("cmux-instance:{value}"));
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

#[cfg(target_os = "linux")]
fn cloud_instance_id() -> Option<String> {
    let value = fs::read_to_string(CLOUD_INSTANCE_FILE).ok()?;
    let value = value.trim();
    (!value.is_empty() && value.len() <= 256 && !value.contains(char::is_whitespace))
        .then(|| value.to_string())
}

/// When this machine's cmux Cloud instance id was bound: the supervisor
/// rewrites its file only for a new instance. `None` off cmux Cloud.
#[cfg(all(not(test), target_os = "linux"))]
fn identity_bound_at() -> Option<SystemTime> {
    cloud_instance_id()?;
    fs::metadata(CLOUD_INSTANCE_FILE).and_then(|meta| meta.modified()).ok()
}

#[cfg(all(not(test), not(target_os = "linux")))]
fn identity_bound_at() -> Option<SystemTime> {
    None
}

#[cfg(test)]
fn identity_bound_at() -> Option<SystemTime> {
    TEST_IDENTITY_BOUND_AT.with(|cell| *cell.borrow())
}

/// Whether the unstamped id file at `path` was made before this machine's
/// cmux Cloud instance id was bound, so on another instance: a fork of a
/// running machine binds its new id after the files it inherited. A file
/// system with no birth time, or a machine off cmux Cloud, answers no. The
/// birth time comes from `statx` ([`cmux_tui_platform::file_birth`]):
/// `Metadata::created` always fails in the static musl build Cloud VMs run.
fn made_before_binding(path: &Path) -> bool {
    let Some(bound) = identity_bound_at() else {
        return false;
    };
    let Some(made) = File::open(path).ok().and_then(|file| file_birth::birth_ns(&file)) else {
        return false;
    };
    bound
        .duration_since(SystemTime::UNIX_EPOCH)
        .is_ok_and(|bound| u128::from(made) < bound.as_nanos())
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
        None if made_before_binding(path) => root_identity::create_machine_id(root, path, true)?,
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
/// is stamped as it is, unless its file was made before this cmux Cloud
/// machine's instance id was bound ([`made_before_binding`]).
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
/// journal, journal segments) keeps what it recorded. Mutation receipts and
/// their events ([`RECEIPT_TABLES`]) keep it too, and are read with the new
/// id: the rehome's cost is the registry's current state, not its history. `session_public_id`
/// stays: the journal records it, and it names the session only within this
/// daemon's resource API. Records other stores hold under the copied id (the
/// app's, other machines') are no longer written by this machine; their
/// owners age them out as they do for a machine that went away.
/// `timings` gets a step per table it rewrote (`registry.migrations.rehome.
/// <table>`, with the rows changed) when the table changed rows or its scan
/// took 1 ms or more.
pub(super) fn rehome_registry(
    connection: &Connection,
    timings: &mut crate::startup_timings::StartupTimings,
) -> anyhow::Result<()> {
    let Some(current) = current_host_stamp() else {
        return Ok(());
    };
    let stored = meta_value(connection, HOST_STAMP_META_KEY)?;
    if stored.as_deref() == Some(current.as_str()) {
        return Ok(());
    }
    let copied_unstamped = stored.is_none()
        && connection
            .path()
            // rusqlite's path is a `&str`: "" for an in-memory database.
            .is_some_and(|path: &str| !path.is_empty() && made_before_binding(Path::new(path)));
    let tx = connection.unchecked_transaction()?;
    if stored.is_some() || copied_unstamped {
        let copied = required_meta(&tx, "registry_id")?;
        rewrite_text_everywhere(&tx, &copied, &try_new_uuid_v4()?, timings)?;
        // After the rewrite, which would move the id in this list too.
        let mut former = StoredIds::load(&tx)?.former;
        former.push(copied);
        tx.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![FORMER_IDS_META_KEY, serde_json::to_string(&former)?],
        )?;
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

/// Tables that describe journal records, one row (or more) per record or
/// segment, and the producers and hooks those records name by id. The
/// journal itself refuses updates, so it keeps the ids it recorded; these
/// keep them too. The history tables are also the ones that grow with
/// history: scanning them made the rehome cost the registry's age (5.5 s of
/// a 7.4 s first start of a 58.7 GB registry on its new machine). What is
/// left to scan is current state, which does not grow with history.
///
/// The set is closed under foreign keys and joins: hook deliveries reference
/// `journal_hooks`, ingress receipts reference `journal_producers`, and kind
/// rows reference `journal_segments` (immutable); no table the rehome still
/// rewrites references one of these or joins on their ids. A hook or
/// producer id that equals the registry id is a coincidence, not a reference
/// to it: no reader keys them by the registry id.
///
/// The rewrite stays in start's transaction and is not moved to a lazy or
/// background pass: until it commits, the registry would answer to two ids,
/// and every reader that keys on the id (the session rows, the sidebar's
/// `sec_m_<id>` sections, `itm_w_<id>_` items, `<id>/<key>` placements,
/// `<id>:<workspace>` layout refs) would have to accept both.
const JOURNAL_TABLES: [&str; 10] = [
    "journal_event_index",
    "legacy_journal_event_index",
    "journal_segment_kinds",
    "journal_segment_reducer_records",
    "journal_pruned_ranges",
    "journal_ingress_receipts",
    "journal_operation_receipts",
    "journal_hook_deliveries",
    "journal_hooks",
    "journal_producers",
];

/// Mutation receipts and the events they recorded: a row per change, so
/// they grow with use (scanning the first five took 1.9 s of a 4.2 s first
/// start of a 58.7 GB registry on its new machine). The resource ledger
/// (`resource_mutations`, `resource_effect_receipts`) is pruned to a window
/// of rows, but its results are large: scanning it took 1.2 s of the same
/// start for 63 rows changed (`resource_mutations`, 1225.5 ms) and 48 ms
/// for none (`resource_effect_receipts`), 2026-11-09. The rehome leaves
/// them as stored and records the id it replaced ([`FORMER_IDS_META_KEY`]);
/// their readers serve the stored text through [`StoredIds`], which moves
/// the references the scan would have moved. Only the JSON columns can hold
/// one (`fingerprint`, `result_json`, `intent_json`, `outcome_json`): the
/// others are client origins and mutation ids, actors, random workspace keys
/// and terminal ids, operation names, states and event kinds. No table the
/// rehome rewrites references them or joins on their JSON; the SQL that
/// reads their JSON matches notification public ids (minted, never a registry
/// id) and the schema migrations that copy `resource_mutations` rows
/// (agent projections, the legacy event journal) run only on registries
/// older than any that has a former id. (`bookmark_mutations` is pruned to
/// a window of small rows, so the scan still covers it.)
const RECEIPT_TABLES: [&str; 7] = [
    "mutations",
    "workspace_events",
    "terminal_events",
    "terminal_mutations",
    "projection_mutations",
    "resource_mutations",
    "resource_effect_receipts",
];

/// In `meta`: the registry ids this registry had before its moves to other
/// machines, oldest first (a JSON array).
const FORMER_IDS_META_KEY: &str = "registry_former_ids";

/// The registry's former ids and its current one: text stored before a
/// move ([`RECEIPT_TABLES`]) is served with its references moved, as the
/// rehome's scan moves them elsewhere.
pub(crate) struct StoredIds {
    current: String,
    former: Vec<String>,
}

impl StoredIds {
    /// One `meta` read; no former ids for a registry that never moved.
    pub(crate) fn load(connection: &Connection) -> anyhow::Result<Self> {
        let former = meta_value(connection, FORMER_IDS_META_KEY)?
            .map(|raw| serde_json::from_str::<Vec<String>>(&raw))
            .transpose()
            .context("read the registry's former ids")?
            .unwrap_or_default();
        let current = if former.is_empty() {
            String::new()
        } else {
            required_meta(connection, "registry_id")?
        };
        Ok(Self { current, former })
    }

    /// `text` with its references to a former id moved to the current one.
    pub(crate) fn text(&self, text: String) -> String {
        self.former.iter().fold(text, |text, old| {
            if !text.contains(old.as_str()) {
                return text;
            }
            rehomed(&text, old, &self.current)
                .or_else(|| rehomed_json(&text, old, &self.current))
                .unwrap_or(text)
        })
    }

    /// A stored canonical fingerprint, moved and canonical again.
    pub(crate) fn fingerprint(&self, stored: String) -> anyhow::Result<String> {
        let moved = self.text(stored.clone());
        if moved == stored {
            return Ok(stored);
        }
        canonical_json(&serde_json::from_str(&moved)?)
    }
}

/// Every mutable table and its columns, less the journal's ([`JOURNAL_TABLES`])
/// and the receipts ([`RECEIPT_TABLES`]), and less every `idempotency_key`:
/// a client's opaque key, never a reference to the registry, on which the
/// resource ledger the rehome leaves as stored is joined (creation receipts,
/// input completions, the ledger's compaction and actor lookups).
fn mutable_columns(connection: &Connection) -> anyhow::Result<Vec<(String, Vec<String>)>> {
    let mut immutable = immutable_tables(connection)?;
    immutable.extend(JOURNAL_TABLES.map(str::to_string));
    immutable.extend(RECEIPT_TABLES.map(str::to_string));
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
            .filter(|column| !matches!(column, Ok(name) if name == "idempotency_key"))
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
fn rewrite_text_everywhere(
    tx: &Transaction<'_>,
    old: &str,
    new: &str,
    timings: &mut crate::startup_timings::StartupTimings,
) -> anyhow::Result<()> {
    tx.execute_batch("PRAGMA defer_foreign_keys=ON;")?;
    for (name, columns) in mutable_columns(tx)? {
        let started = std::time::Instant::now();
        let mut changed = 0_u64;
        let table = quote_identifier(&name);
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
                    let rows = tx.execute(
                        &format!("UPDATE {table} SET {column} = ?2 WHERE {column} = ?1"),
                        params![text, replacement],
                    )?;
                    changed += rows as u64;
                }
            }
        }
        let took = started.elapsed();
        if changed > 0 || took >= std::time::Duration::from_millis(1) {
            timings.record_rows(format!("registry.migrations.rehome.{name}"), took, changed);
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
mod tests;
