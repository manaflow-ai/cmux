//! The damage record (`DAMAGE`): what earlier opens found, kept and reported at every open until
//! `Journal::clear_damage` moves it into `quarantine/` (step 5 of `recovery.rs`).

use std::path::Path;

use super::{CLEARED_DAMAGE, DAMAGE_NAME, QUARANTINE_DIR, STAGING_SUFFIX, io, usize_of};
use crate::journal::OpenError;
use crate::recovery::Damage;
use crate::storage::{OpenMode, Storage, SyncLevel};

/// The damage that earlier opens recorded (`DAMAGE`, one line each), none when there is no file.
/// A line that does not read is reported as damage itself, so no report is lost silently.
pub(super) fn read_damage(storage: &dyn Storage, dir: &Path) -> Result<Vec<Damage>, OpenError> {
    let file = match storage.open(&dir.join(DAMAGE_NAME), OpenMode::Read) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(OpenError::Io { what: "open the damage record".into(), error }),
    };
    let size = file.size().map_err(io("read the damage record's size"))?;
    let mut bytes = vec![0u8; usize_of(size)];
    file.read_at(0, &mut bytes).map_err(io("read the damage record"))?;
    let text = String::from_utf8_lossy(&bytes);
    Ok(text.lines().filter(|line| !line.is_empty()).map(decode_damage).collect())
}

/// Writes every [`Damage::Corrupt`] of `damage` to `DAMAGE`: whole under a staging name, fully
/// synced, renamed into place, folder synced.
pub(super) fn write_damage(
    storage: &dyn Storage,
    dir: &Path,
    damage: &[Damage],
) -> std::io::Result<()> {
    let mut text = String::new();
    for entry in damage {
        if let Damage::Corrupt { segment, offset, reason, moved, lost_after, lost_through } = entry
        {
            let clean = |field: &str| field.replace(['\t', '\n', '\r'], " ");
            let moved: Vec<String> = moved.iter().map(|name| clean(name.as_str())).collect();
            text.push_str(&format!(
                "corrupt\t{}\t{offset}\t{lost_after}\t{lost_through}\t{}\t{}\n",
                clean(segment.as_str()),
                moved.join(","),
                clean(reason.as_str()),
            ));
        }
    }
    let staging = dir.join(format!("{DAMAGE_NAME}{STAGING_SUFFIX}"));
    let mut file = storage.open(&staging, OpenMode::Create)?;
    file.append(text.as_bytes())?;
    file.sync(SyncLevel::Full)?;
    storage.rename(&staging, &dir.join(DAMAGE_NAME))?;
    storage.sync_dir(dir)
}

/// One line of `DAMAGE`; a line that does not read is damage itself.
fn decode_damage(line: &str) -> Damage {
    let fields: Vec<&str> = line.splitn(7, '\t').collect();
    let number = |index: usize| fields.get(index).and_then(|field| field.parse::<u64>().ok());
    match (
        fields.first(),
        fields.get(1),
        number(2),
        number(3),
        number(4),
        fields.get(5),
        fields.get(6),
    ) {
        (
            Some(&"corrupt"),
            Some(segment),
            Some(offset),
            Some(lost_after),
            Some(lost_through),
            Some(moved),
            Some(reason),
        ) => Damage::Corrupt {
            segment: (*segment).to_owned(),
            offset,
            reason: (*reason).to_owned(),
            moved: moved.split(',').filter(|name| !name.is_empty()).map(str::to_owned).collect(),
            lost_after,
            lost_through,
        },
        _ => Damage::Corrupt {
            segment: DAMAGE_NAME.to_owned(),
            offset: 0,
            reason: format!("a line of the damage record does not read: {line}"),
            moved: Vec::new(),
            lost_after: 0,
            lost_through: 0,
        },
    }
}

/// Moves `DAMAGE` into `quarantine/` (kept, never deleted), so later opens report no damage that
/// the daemon already told the person about. No file: nothing to do.
pub(crate) fn clear_damage(storage: &dyn Storage, dir: &Path) -> std::io::Result<()> {
    let from = dir.join(DAMAGE_NAME);
    match storage.open(&from, OpenMode::Read) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    }
    let target = dir.join(QUARANTINE_DIR);
    storage.create_dir_all(&target)?;
    let taken = storage.list(&target)?;
    let mut attempt = 0u32;
    let name = loop {
        let candidate = format!("{CLEARED_DAMAGE}.{attempt}");
        if !taken.contains(&candidate) {
            break candidate;
        }
        attempt = attempt.saturating_add(1);
    };
    storage.rename(&from, &target.join(name))?;
    storage.sync_dir(&target)?;
    storage.sync_dir(dir)
}
