//! Two projection dials, each answering reads in its own manifest's index space.

use std::io::BufReader;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::bail;
use serde_json::{Value, json};

use super::super::{base, local};
use super::{
    CarryFiles, GIVE_UP_AFTER, Listed, Offer, Rules, base_of_listing, code, dial, elapsed_ms,
    from_set, hold_lock, keep_base, note_failure, ok, packs, print_ready, projection_carry,
    ready_timing, record_listing, redial, retry_wait, serve_full, serve_reads, stamp_ready,
};

/// The head: the root's own entries and its folders, and the harness folders' files (`.claude`,
/// `.codex`, ...), which an agent reads as it starts. The folders it names, for the whole listing.
pub(super) fn list_head(folder: &Path) -> anyhow::Result<(Listed, Vec<String>)> {
    let (set, dirs) = local::listed_projection(folder, true)?;
    let listed = from_set(folder, set, dirs.clone(), None)?;
    Ok((listed, dirs))
}

/// The whole folder as the copy lists it ([`local::listed`]), the carry files too, and the head's
/// folders, so it holds every entry the head mounted (the machine refuses an extend that drops
/// one: `projection.extend_not_superset`).
/// The carry files are served from their own folder for as long as the listing is: the caller
/// keeps them.
pub(super) fn list_full(
    folder: &Path,
    dirs: Vec<String>,
) -> anyhow::Result<(Listed, Option<CarryFiles>)> {
    let carry = projection_carry(folder);
    let (set, _) = local::listed(folder, Rules::Copy, None)?;
    let listed = from_set(folder, set, dirs, carry.as_ref())?;
    Ok((listed, carry))
}

/// The start has already consumed the server's one stdout reply.
#[derive(Debug)]
pub(super) struct AfterHeadReady(String);

impl std::fmt::Display for AfterHeadReady {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "cannot finish projecting {} after the head mounted", self.0)
    }
}

pub(super) fn serve_head(
    socket: &Path,
    name: &str,
    at: &str,
    folder: &Path,
    started: Instant,
) -> anyhow::Result<Value> {
    let (head, dirs) = list_head(folder)?;
    let listed_ms = elapsed_ms(started);
    let encoded = head.manifest.encode()?;
    let encoded_ms = elapsed_ms(started);
    let (reader, mut answer) = dial(socket, name, at, &encoded, Offer::Head)?;
    if !ok(&answer) {
        return Ok(answer);
    }
    let packed = packs(&answer);
    let close_head = reader.get_ref().try_clone()?;
    let _lock = hold_lock(at);
    if let Some(data) = answer.get_mut("data").and_then(Value::as_object_mut) {
        data.insert("head_entries".into(), json!(head.manifest.len()));
        data.insert("head_ms".into(), json!(elapsed_ms(started)));
    }
    let timing = ready_timing(
        head.manifest.len(),
        listed_ms,
        encoded_ms,
        encoded.len(),
        elapsed_ms(started),
        answer.pointer("/data/mount_ms").and_then(Value::as_u64),
    );
    stamp_ready(&mut answer, timing, head.manifest.kept_count());
    print_ready(&answer);

    drop(encoded);
    let prepared = std::thread::scope(|scope| {
        scope.spawn(|| serve_reads(reader, &head, packed));
        let result = (|| -> anyhow::Result<_> {
            let (full, carry) = list_full(folder, dirs)?;
            let encoded = full.manifest.encode()?;
            let made = (!base::kept(folder, at)).then(|| base_of_listing(folder, &full));
            let stream = extend(socket, name, at, &encoded)?;
            // The whole folder behind the head: what the start no longer waits for.
            eprintln!(
                "cmux link project: whole folder {}",
                json!({"entries": full.manifest.len(), "manifest_bytes": encoded.len(),
                       "full_ms": elapsed_ms(started)})
            );
            if let Some(base) = made
                && let Err(error) = base.and_then(|base| keep_base(folder, at, &base))
            {
                eprintln!("cmux link project: no base for Bring Back: {error:#}");
            }
            record_listing(name, at, folder, &encoded);
            Ok((full, carry, encoded, stream))
        })();
        // The old dial can still be blocked reading an ask after the machine switches writers.
        // End it on every exit before joining its reader.
        let _ = close_head.shutdown(Shutdown::Both);
        result
    });
    drop(close_head);
    drop(head);
    let (full, _carry, encoded, stream) =
        prepared.map_err(|error| error.context(AfterHeadReady(at.to_owned())))?;
    serve_full(socket, name, at, folder, &encoded, &full, (stream, packed));
    Ok(Value::Null)
}

/// Retry the same full offer if the answer was lost. A machine that restarted has no
/// mount to extend; a folder that changed kind while being listed needs a fresh mount.
fn extend(
    socket: &Path,
    name: &str,
    at: &str,
    encoded: &[u8],
) -> anyhow::Result<BufReader<UnixStream>> {
    let began = Instant::now();
    let mut backoff = Duration::from_millis(200);
    let mut last_error = None;
    let mut offer = Offer::Extend;
    loop {
        let (dialed, quiet) = redial(socket, name, at, encoded, offer);
        match dialed {
            Ok((reader, answer)) if ok(&answer) => {
                if let Some(ms) = answer.pointer("/data/extend_ms").and_then(Value::as_u64) {
                    eprintln!("cmux link project: {at} extended: extend_ms={ms}");
                }
                return Ok(reader);
            }
            Ok((_, answer))
                if matches!(offer, Offer::Extend)
                    && matches!(
                        code(&answer),
                        Some("projection.unknown" | "projection.extend_not_superset")
                    ) =>
            {
                eprintln!("cmux link project: sending the full mount after {answer}");
                offer = Offer::Full;
            }
            Ok((_, answer)) => bail!("the machine refused the full listing: {answer}"),
            Err(error) => {
                if began.elapsed() >= GIVE_UP_AFTER {
                    return Err(error);
                }
                note_failure(&mut last_error, &error);
                std::thread::sleep(retry_wait(quiet, &mut backoff));
            }
        }
    }
}
