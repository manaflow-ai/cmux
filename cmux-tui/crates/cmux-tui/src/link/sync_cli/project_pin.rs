//! `cmux link project pin | unpin | pins`: keep a part of a projected folder whole on the Cloud
//! machine's disk, so it reads there with this Mac asleep or offline: the "Make available
//! offline" / "Keep Downloaded" / "Always keep on this device" of Dropbox, Google Drive, iCloud
//! Drive and OneDrive, for a folder this Mac projects (`cmux_projection::overlay::pin`).
//!
//! Better than theirs: a pin is sized against the machine's disk before anything is fetched and
//! refused up front when it would not fit (never half fetched, never evicted later because the OS
//! decided), it survives a restart and a new manifest, and `pins` says, per pin, how many of its
//! bytes are on the machine now.
//!
//!     cmux link project pin --socket S --at REMOTE FOLDER PATH
//!     cmux link project unpin --socket S --at REMOTE FOLDER PATH
//!     cmux link project pins --socket S --at REMOTE FOLDER
//!
//! `PATH` is a path in `FOLDER` (on this Mac), in `REMOTE` (the machine's mount), or relative to
//! the folder; `.` is all of it. `--name N` in place of `FOLDER` names the projection itself (on
//! the machine, where this Mac's records are not). `pin` answers once every file is on the
//! machine's disk, or with `"away": true` when this Mac stopped answering first: the pin holds and
//! the machine finishes it when the folder is projected again.

use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use anyhow::{Context as _, bail};
use serde_json::{Value, json};

use super::project_back::{dial_answer_within, field, recorded};

/// How long a pin waits for the machine to fetch everything under it.
const PIN_WAIT: Duration = Duration::from_secs(2 * 60 * 60);
/// How long an unpin or a listing waits.
const STATUS_WAIT: Duration = Duration::from_secs(120);

/// What a pin command names.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct PinArgs {
    pub socket: Option<PathBuf>,
    pub at: Option<String>,
    pub name: Option<String>,
    /// The positional words: `FOLDER PATH`, or `PATH` with `--name`.
    pub words: Vec<String>,
}

pub(crate) fn parse(args: &[String]) -> anyhow::Result<PinArgs> {
    let mut parsed = PinArgs::default();
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--socket" => parsed.socket = words.next().map(PathBuf::from),
            "--at" => parsed.at = words.next().cloned(),
            "--name" => parsed.name = Some(words.next().cloned().context("--name needs a name")?),
            other if other.starts_with("--") => bail!("unknown flag {other}"),
            other => parsed.words.push(other.to_owned()),
        }
    }
    Ok(parsed)
}

/// `pin`, `unpin` or `pins` (module docs): one JSON line, `{"ok": true, ...the machine's data}`.
pub(crate) fn command(cmd: &str, args: &[String]) -> anyhow::Result<Value> {
    let args = parse(args)?;
    let socket = args.socket.as_deref().context("--socket is required")?;
    let at = args.at.as_deref().context("--at is required")?;
    let wants_path = cmd != "pins";
    let (name, folder, path) = match (&args.name, args.words.as_slice()) {
        (Some(name), [path]) if wants_path => (name.clone(), None, Some(path.as_str())),
        (Some(name), []) if !wants_path => (name.clone(), None, None),
        (None, [folder, path]) if wants_path => {
            let found = found(Path::new(folder), at)?;
            (found.0, Some(found.1), Some(path.as_str()))
        }
        (None, [folder]) if !wants_path => {
            let found = found(Path::new(folder), at)?;
            (found.0, Some(found.1), None)
        }
        _ => bail!("{}", usage()),
    };
    let mut line = json!({"cmd": format!("projection.{cmd}"), "name": name});
    if let (Some(path), Some(fields)) = (path, line.as_object_mut()) {
        let relative = folder_path(folder.as_deref(), at, path)?;
        fields.insert("path".into(), Value::from(relative));
    }
    let wait = if cmd == "pin" { PIN_WAIT } else { STATUS_WAIT };
    match dial_answer_within(socket, &line, wait)? {
        Ok(answer) => {
            let mut out = json!({"ok": true});
            if let (Some(fields), Value::Object(data)) =
                (out.as_object_mut(), field(&answer, "/data").clone())
            {
                fields.extend(data);
            }
            Ok(out)
        }
        Err(answer) => {
            let code = field(&answer, "/error_code").clone();
            let unserved = code.is_null() || code.as_str() == Some("projection.unknown_op");
            let error = if unserved {
                Value::from(
                    "the machine does not serve pinned folders; `cmux link project pins` works once it serves projection.pins",
                )
            } else {
                field(&answer, "/error").clone()
            };
            Ok(json!({"ok": false, "error": error, "error_code": code}))
        }
    }
}

pub(crate) fn usage() -> &'static str {
    "usage: cmux link project pin --socket S --at REMOTE FOLDER PATH | unpin --socket S --at \
     REMOTE FOLDER PATH | pins --socket S --at REMOTE FOLDER (--name N in place of FOLDER)"
}

/// The projection name and this Mac's folder recorded for `folder` at `at`.
fn found(folder: &Path, at: &str) -> anyhow::Result<(String, PathBuf)> {
    let found = recorded(folder, at)
        .with_context(|| format!("{} is not a projected folder at {at}", folder.display()))?;
    Ok((found.name, found.local))
}

/// `path` relative to the projected folder, `/`-separated: an absolute path inside `folder`
/// (this Mac's) or `remote` (the machine's mount) loses that prefix, a relative one is taken as
/// is. `.` and empty names go, `..` and a path outside both are refused. `""` is the whole folder.
pub(crate) fn folder_path(
    folder: Option<&Path>,
    remote: &str,
    path: &str,
) -> anyhow::Result<String> {
    let given = Path::new(path);
    let inside = if given.is_absolute() {
        // This Mac's folder is recorded canonical: a path through a link is read canonical too.
        let canonical = std::fs::canonicalize(given).ok();
        let in_folder = folder.and_then(|folder| {
            given
                .strip_prefix(folder)
                .ok()
                .or_else(|| canonical.as_deref()?.strip_prefix(folder).ok())
        });
        in_folder
            .or_else(|| given.strip_prefix(remote).ok())
            .map(Path::to_path_buf)
            .with_context(|| format!("{path} is not in the projected folder"))?
    } else {
        given.to_path_buf()
    };
    let mut names = Vec::new();
    for part in inside.components() {
        match part {
            Component::Normal(name) => {
                names.push(name.to_str().with_context(|| format!("{path} is not UTF-8"))?);
            }
            Component::CurDir => {}
            _ => bail!("{path}: a path in the folder has no `..`"),
        }
    }
    Ok(names.join("/"))
}

#[cfg(test)]
#[path = "project_pin_tests.rs"]
mod tests;
