//! The sender's half of `git-seed-carry-v1`: the seed's base packed from this repository's own
//! objects, so the machine builds a fresh folder from it instead of cloning GitHub
//! (`cmux-tui-core` `git_seed/carry.rs` is the machine's half).
//!
//! The pack holds the base commit, its tree and every blob of it, and nothing older: git's
//! `pack-objects` walks the base as a shallow boundary (`--shallow BASE`) and reuses the deltas
//! the repository's packs already hold, so it is a copy of bytes on disk more than a compression.
//!
//! The switch is `CMUX_SEED_CARRY`: `off` never carries; anything else (the default) carries
//! whenever the machine serves `git-seed-carry-v1`, the repository is not a partial clone (a
//! blob it lacks would be fetched from GitHub here first) and the pack is at most
//! the cap `cmux link seed push` picks from the measured link speed to the machine
//! (`seed_cli/link_speed.rs`: `CMUX_SEED_CARRY_MAX_MB` when set, else what the link sends in
//! `CMUX_SEED_CARRY_BUDGET_S`, else [`DEFAULT_MAX_MB`]); past that the machine's own clone is the
//! better bet over a slow uplink.

use std::io::Write as _;
use std::path::Path;
use std::process::Stdio;

use super::git;

/// The largest pack carried by default, in MiB.
pub const DEFAULT_MAX_MB: u64 = 512;

/// Whether this process may carry at all (`CMUX_SEED_CARRY`).
#[must_use]
pub fn enabled() -> bool {
    !std::env::var("CMUX_SEED_CARRY").is_ok_and(|value| value.eq_ignore_ascii_case("off"))
}

/// Writes the depth-1 pack of `base` from the repository at `folder` to `out`; its bytes.
/// `Err` (why) when it cannot or should not be carried (past `max_bytes`, among others): the
/// seed then goes without it.
pub fn pack(folder: &Path, base: &str, out: &Path, max_bytes: u64) -> Result<u64, String> {
    pack_with_filter(folder, base, out, false, max_bytes)
}

/// Writes the projection carry pack: commits and trees for the depth-one base while leaving blobs
/// to the projected repository. Staged blobs are fetched explicitly from the
/// projected repository when the machine copies its index.
pub fn pack_projection(folder: &Path, base: &str, out: &Path) -> Result<u64, String> {
    pack_with_filter(folder, base, out, true, DEFAULT_MAX_MB * 1024 * 1024)
}

fn pack_with_filter(
    folder: &Path,
    base: &str,
    out: &Path,
    blobless: bool,
    max_bytes: u64,
) -> Result<u64, String> {
    if git::optional(git::at(folder).args(["config", "--get", "extensions.partialClone"])).is_some()
    {
        return Err("the repository is a partial clone".into());
    }
    let file = std::fs::File::create(out).map_err(|error| format!("cannot write: {error}"))?;
    let mut command = git::at(folder);
    command.args(["pack-objects"]);
    if blobless {
        command.arg("--filter=blob:none");
    }
    command
        .args(["--revs", "--stdout", "-q", "--delta-base-offset"])
        .stdin(Stdio::piped())
        .stdout(file)
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|error| format!("cannot run git: {error}"))?;
    let input = format!("--shallow {base}\n{base}\n");
    let wrote =
        child.stdin.take().map(|mut stdin| stdin.write_all(input.as_bytes())).unwrap_or(Ok(()));
    let done = child.wait_with_output().map_err(|error| format!("cannot run git: {error}"))?;
    if !done.status.success() || wrote.is_err() {
        let _ = std::fs::remove_file(out);
        return Err(format!(
            "pack-objects failed: {}",
            String::from_utf8_lossy(&done.stderr).trim()
        ));
    }
    let bytes = std::fs::metadata(out).map_err(|error| format!("cannot read: {error}"))?.len();
    if bytes > max_bytes {
        let _ = std::fs::remove_file(out);
        return Err(format!("the pack is {bytes} bytes, over the {max_bytes}-byte cap"));
    }
    Ok(bytes)
}
