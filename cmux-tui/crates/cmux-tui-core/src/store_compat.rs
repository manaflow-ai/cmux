//! Rollback-safe schema stamps for the daemon's SQLite stores.
//!
//! Each store's `meta` table carries three stamps:
//!
//! - `schema_version`: the format the file is in (the writer's schema);
//! - `written_by_version`: the cmux-tui version that last stamped it;
//! - `min_reader_schema`: the oldest schema whose build can still read it.
//!
//! A store with no `min_reader_schema` was stamped before this rule, so its
//! `schema_version` is its min reader too.
//!
//! The rule (docs/cloud-cmux-tui-daemon.md, "Store versions and rollback"):
//!
//! - A migration that only adds optional state (a nullable or defaulted
//!   column, a new table the old build never reads) bumps `schema_version`
//!   and keeps the store's [`StoreRule::min_reader`]. An older build whose
//!   schema is at least that min reader opens the newer file as it is: it
//!   does not migrate it and never lowers a stamp.
//! - A breaking migration raises [`StoreRule::min_reader`] above the schema
//!   it migrates from, and keeps the pre-migration file first as
//!   `<file>.v<N>.bak` ([`keep_backup`]), N the schema it held.
//! - A build older than the store's min reader refuses to open it with a
//!   message naming the stored and own versions and the newest backup it
//!   can read ([`refusal_text`]). It never wipes or rewrites the file.
//! - [`restore_backup`] rolls a store back to a backup: the current file and
//!   its sidecars move aside first, so nothing is deleted.

use std::path::{Path, PathBuf};

use anyhow::Context as _;
use rusqlite::{Connection, OptionalExtension as _, params};

pub(crate) const MIN_READER_KEY: &str = "min_reader_schema";
pub(crate) const WRITTEN_BY_KEY: &str = "written_by_version";
/// The version [`WRITTEN_BY_KEY`] records for this build.
pub(crate) const BUILD_VERSION: &str = env!("CARGO_PKG_VERSION");
/// Beside the store: where [`restore_backup`] moves the replaced file.
pub(crate) const ROLLBACK_ASIDE_DIR: &str = "store-rollback";
const SIDECAR_SUFFIXES: [&str; 3] = ["-wal", "-journal", "-shm"];

/// One store's place in the rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct StoreRule {
    /// For messages: "workspace registry", "conversation store".
    pub label: &'static str,
    /// The schema this build writes.
    pub schema: i64,
    /// The oldest schema whose build reads what this build writes. Equal to
    /// `schema` after a breaking migration; kept on an additive one.
    pub min_reader: i64,
}

/// The stamps a store holds.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Stamps {
    pub schema: Option<i64>,
    pub min_reader: Option<i64>,
    pub written_by: Option<String>,
}

impl Stamps {
    /// The store's min reader: its stamp, else (a file from before the rule)
    /// its schema.
    pub fn effective_min_reader(&self) -> Option<i64> {
        self.min_reader.or(self.schema)
    }
}

/// What a build does with a store it opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// No schema yet: create it and stamp it.
    Fresh,
    /// The build's own schema.
    Current,
    /// An older schema: migrate it. `backup` when a build of `from` cannot
    /// read the result, so the pre-migration file is kept first.
    Migrate { from: i64, backup: bool },
    /// A newer schema this build can read: open it as it is, migrate and
    /// stamp nothing.
    ReadNewer { found: i64 },
    /// A store this build cannot read: refuse, change nothing.
    Refuse { found: i64, min_reader: i64 },
}

impl Verdict {
    /// The build may write its own stamps (it is the newest writer).
    pub fn stamps(self) -> bool {
        matches!(self, Self::Fresh | Self::Current | Self::Migrate { .. })
    }
}

pub(crate) fn verdict(rule: StoreRule, stamps: &Stamps) -> Verdict {
    let Some(found) = stamps.schema else {
        return Verdict::Fresh;
    };
    let min_reader = stamps.effective_min_reader().unwrap_or(found);
    if min_reader > rule.schema {
        return Verdict::Refuse { found, min_reader };
    }
    match found.cmp(&rule.schema) {
        std::cmp::Ordering::Greater => Verdict::ReadNewer { found },
        std::cmp::Ordering::Equal => Verdict::Current,
        std::cmp::Ordering::Less => {
            Verdict::Migrate { from: found, backup: rule.min_reader > found }
        }
    }
}

fn meta_text(connection: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    let has_meta: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta')",
        [],
        |row| row.get(0),
    )?;
    if !has_meta {
        return Ok(None);
    }
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get(0))
        .optional()?)
}

fn meta_number(connection: &Connection, key: &str, label: &str) -> anyhow::Result<Option<i64>> {
    meta_text(connection, key)?
        .map(|value| value.parse::<i64>().with_context(|| format!("{label} {key} is invalid")))
        .transpose()
}

pub(crate) fn read_stamps(connection: &Connection, label: &str) -> anyhow::Result<Stamps> {
    Ok(Stamps {
        schema: meta_number(connection, "schema_version", label)?,
        min_reader: meta_number(connection, MIN_READER_KEY, label)?,
        written_by: meta_text(connection, WRITTEN_BY_KEY)?,
    })
}

/// Writes `min_reader_schema` and `written_by_version` for `rule`. The caller
/// writes `schema_version` with its migration, and calls this only for a
/// verdict that [`Verdict::stamps`].
pub(crate) fn stamp_reader(connection: &Connection, rule: StoreRule) -> anyhow::Result<()> {
    for (key, value) in
        [(MIN_READER_KEY, rule.min_reader.to_string()), (WRITTEN_BY_KEY, BUILD_VERSION.to_string())]
    {
        connection.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
    }
    Ok(())
}

fn with_tail(path: &Path, tail: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(tail);
    PathBuf::from(name)
}

/// `<file>.v<schema>.bak`: the copy of `database` kept before a breaking
/// migration from `schema`.
pub(crate) fn backup_path(database: &Path, schema: i64) -> PathBuf {
    with_tail(database, &format!(".v{schema}.bak"))
}

/// Keeps a consistent copy of the store open on `connection` as
/// [`backup_path`]`(database, from)`, unless one is there already (the first
/// copy is the one from before any attempt). The caller is the store's only
/// writer and is not in a transaction. When a full WAL checkpoint succeeds
/// the main file alone is the store, and it is copied as a file (a clone on
/// APFS and reflink filesystems, so a large registry costs no time or
/// space); else `VACUUM INTO` writes a copy from one read transaction. The
/// copy goes to a temporary name renamed into place, private to the user.
pub(crate) fn keep_backup(
    connection: &Connection,
    database: &Path,
    from: i64,
) -> anyhow::Result<PathBuf> {
    let backup = backup_path(database, from);
    if backup.is_file() {
        return Ok(backup);
    }
    let partial = with_tail(&backup, ".partial");
    if partial.exists() {
        std::fs::remove_file(&partial)
            .with_context(|| format!("remove partial backup {}", partial.display()))?;
    }
    let (busy, log, checkpointed): (i64, i64, i64) = connection
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .unwrap_or((1, 0, 0));
    if busy == 0 && log == checkpointed {
        std::fs::copy(database, &partial)
            .with_context(|| format!("back up {} to {}", database.display(), partial.display()))?;
    } else {
        let target = partial.to_str().context("backup path is not UTF-8")?;
        connection
            .execute("VACUUM INTO ?1", [target])
            .with_context(|| format!("back up {} to {}", database.display(), partial.display()))?;
    }
    crate::platform::restrict_file(&partial)
        .with_context(|| format!("restrict backup {}", partial.display()))?;
    std::fs::rename(&partial, &backup)
        .with_context(|| format!("keep backup {}", backup.display()))?;
    Ok(backup)
}

/// The backup of `database` with the newest schema at most `readable`: the
/// one a build that reads `readable` can roll back to.
pub(crate) fn newest_backup(database: &Path, readable: i64) -> Option<PathBuf> {
    let directory = database.parent()?;
    let name = database.file_name()?.to_str()?;
    let prefix = format!("{name}.v");
    std::fs::read_dir(directory)
        .ok()?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let file = entry.file_name();
            let schema =
                file.to_str()?.strip_prefix(&prefix)?.strip_suffix(".bak")?.parse::<i64>().ok()?;
            (schema <= readable && entry.path().is_file()).then(|| (schema, entry.path()))
        })
        .max_by_key(|(schema, _)| *schema)
        .map(|(_, path)| path)
}

/// The refusal of a build that reads `own` (an older build) to open a store
/// of schema `found` whose min reader is `min_reader`.
pub(crate) fn refusal_text(
    label: &str,
    found: i64,
    min_reader: i64,
    own: i64,
    written_by: Option<&str>,
    database: Option<&Path>,
    backup: Option<&Path>,
) -> String {
    let writer = written_by.map(|version| format!(" by cmux-tui {version}")).unwrap_or_default();
    let mut text = format!(
        "unsupported {label} schema {found}; newest supported is {own}: the store was written{writer} \
         at schema {found} and needs a reader of schema {min_reader} or newer, and this build \
         (cmux-tui {BUILD_VERSION}) reads schema {own}. Nothing was changed"
    );
    if let Some(database) = database {
        text.push_str(&format!(" at {}", database.display()));
    }
    match backup {
        Some(backup) => text.push_str(&format!(
            ". To roll back, stop the newer daemon and run `cmux-tui __store-schemas --restore {}`; \
             changes since the upgrade stay in the moved-aside copy",
            backup.display()
        )),
        None => text.push_str(&format!(
            ". No backup at schema {own} or older is kept; run a build that reads schema {min_reader}"
        )),
    }
    text
}

/// Rolls a store back to `backup` (a [`backup_path`]). The store file and its
/// sidecars move into `<dir>/store-rollback/<millis>/` first; then `backup`
/// is copied (kept itself) into the store's place. Returns the aside folder.
/// The store must not be open: run it with its daemon stopped.
pub(crate) fn restore_backup(backup: &Path) -> anyhow::Result<PathBuf> {
    let database = database_of_backup(backup)
        .with_context(|| format!("{} is not a store backup (<file>.v<N>.bak)", backup.display()))?;
    anyhow::ensure!(backup.is_file(), "backup {} does not exist", backup.display());
    let directory = database.parent().context("store has no folder")?;
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or(0);
    let aside = directory.join(ROLLBACK_ASIDE_DIR).join(millis.to_string());
    std::fs::create_dir_all(&aside).with_context(|| format!("create {}", aside.display()))?;
    let name = database.file_name().context("store has no name")?;
    for tail in std::iter::once("").chain(SIDECAR_SUFFIXES) {
        let from = with_tail(&database, tail);
        if from.exists() {
            let mut moved = name.to_os_string();
            moved.push(tail);
            std::fs::rename(&from, aside.join(moved))
                .with_context(|| format!("move {} aside", from.display()))?;
        }
    }
    let partial = with_tail(&database, ".restore-partial");
    std::fs::copy(backup, &partial)
        .with_context(|| format!("copy {} to {}", backup.display(), partial.display()))?;
    crate::platform::restrict_file(&partial)
        .with_context(|| format!("restrict {}", partial.display()))?;
    std::fs::rename(&partial, &database)
        .with_context(|| format!("restore {}", database.display()))?;
    Ok(aside)
}

/// The store a `<file>.v<N>.bak` backs up.
fn database_of_backup(backup: &Path) -> Option<PathBuf> {
    let name = backup.file_name()?.to_str()?;
    let stem = name.strip_suffix(".bak")?;
    let (file, schema) = stem.rsplit_once(".v")?;
    schema.parse::<i64>().ok()?;
    (!file.is_empty()).then(|| backup.with_file_name(file))
}

#[cfg(test)]
#[path = "store_compat_tests.rs"]
mod tests;
