//! A recording's bundle: the rings and the Chromium JSON `record` copies into `--out`, the
//! `manifest.json` that names them, and the exporter seam over it.
//!
//! The bundle carries what task 022's exporter (`cmux_trace::export`) reads: each ring with the
//! machine it was recorded on (`ExportInput::rings`, `Machine`), the remote machines with their
//! measured offset and error bound (`ExportInput::remotes`, task 116), and the Chromium trace with
//! its clock offset (`ChromiumInput::offset_ns`). The manifest stores the same, so `cmux trace
//! export` builds the bundle again from a recorded directory.
//!
//! The stop reply (task 020, `ControlRouter+Trace.swift` `finish`) is `{recording, stopped_by,
//! app, daemon, chromium?}`: `app` is the app ring's state (`state`, `path`, `recording_bytes`),
//! `daemon` the daemon's `trace-stop` reply (`server/trace_control.rs`: `processes`, each with
//! `role`, `pid`, `state`, `recording_path` or `reason`/`error`) or the part's error
//! (`{state, error}`), and `chromium` the Chromium part's reply (task 051: the JSON file's `path`
//! and the measured `offset_ns`), or its `{state, reason|error}`.

use std::path::{Component, Path, PathBuf};

use serde_json::{Value, json};

use super::{CHROMIUM_FILE, Failure, MANIFEST_FILE, RINGS_DIR};

/// The files `record` collected: the exporter's input.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Bundle {
    pub dir: PathBuf,
    /// The machines other than the local one; [`RingMachine::Remote`] indexes them.
    pub remotes: Vec<RemoteMachine>,
    pub rings: Vec<RingFile>,
    pub chromium: Option<ChromiumFile>,
}

/// A machine other than the one the recording ran on (task 116): its rings are on its own clock.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct RemoteMachine {
    pub name: String,
    /// Its trace clock minus the local trace clock, in ns.
    pub offset_ns: i64,
    pub error_bound_ns: u64,
}

/// Which machine a ring was recorded on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum RingMachine {
    Local,
    /// An index into [`Bundle::remotes`].
    Remote(usize),
}

/// One recording ring, copied to `path` under [`RINGS_DIR`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct RingFile {
    pub role: String,
    pub pid: Option<u64>,
    pub machine: RingMachine,
    pub path: PathBuf,
}

/// Chromium's JSON trace, copied to `path`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct ChromiumFile {
    pub path: PathBuf,
    /// Added to Chromium's timestamps to put them on the local trace clock, in ns, as the
    /// Chromium part measured it. `None` when the reply had none: the exporter then takes 0
    /// (`base::TimeTicks` is the trace clock on macOS).
    pub offset_ns: Option<i64>,
}

/// The Perfetto exporter over a [`Bundle`]; [`PerfettoExport`] in the CLI.
pub(in crate::cli) trait TraceExporter {
    /// Whether this build has an exporter; without one the bundle is the result.
    fn available(&self) -> bool;
    /// Writes the bundle as one Perfetto trace at `to`.
    fn export(&self, bundle: &Bundle, to: &Path) -> Result<(), String>;
}

/// `cmux_trace::export` (task 022) is not on this branch yet. When it is, this decodes each ring
/// and passes the bundle as its `ExportInput`, field for field.
pub(in crate::cli) struct PerfettoExport;

impl TraceExporter for PerfettoExport {
    fn available(&self) -> bool {
        false
    }

    fn export(&self, _bundle: &Bundle, _to: &Path) -> Result<(), String> {
        Err("this build has no Perfetto exporter".to_owned())
    }
}

/// One process of a trace reply, from either of its shapes: the app part's (`path`) or a daemon
/// entry's (`recording_path`).
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct ProcessEntry<'a> {
    pub role: &'a str,
    pub pid: Option<u64>,
    pub state: Option<&'a str>,
    pub ring: Option<&'a str>,
    pub reason: Option<&'a str>,
}

impl<'a> ProcessEntry<'a> {
    fn of(value: &'a Value, role: &'a str) -> Self {
        let field = |key: &str| value.get(key).and_then(Value::as_str);
        ProcessEntry {
            role: field("role").unwrap_or(role),
            pid: value.get("pid").and_then(Value::as_u64),
            state: field("state"),
            ring: field("recording_path").or_else(|| field("path")),
            reason: field("reason").or_else(|| field("error")),
        }
    }

    /// Why this entry has no ring to copy.
    fn missing(&self) -> &'a str {
        self.reason.or(self.state).unwrap_or("no_ring")
    }
}

/// Every process with a ring in a start, stop or status reply: the app, then the daemon's
/// processes, or the daemon itself when its part failed.
pub(in crate::cli) fn process_entries(reply: &Value) -> Vec<ProcessEntry<'_>> {
    let mut entries = Vec::new();
    if let Some(app) = reply.get("app").filter(|app| app.is_object()) {
        entries.push(ProcessEntry::of(app, "app"));
    }
    if let Some(daemon) = reply.get("daemon").filter(|daemon| daemon.is_object()) {
        match daemon.get("processes").and_then(Value::as_array) {
            Some(processes) => {
                entries
                    .extend(processes.iter().map(|process| ProcessEntry::of(process, "unknown")));
            }
            None => entries.push(ProcessEntry::of(daemon, "daemon")),
        }
    }
    entries
}

/// The Chromium part of a start or stop reply (a status reply's `chromium` is a flag).
pub(in crate::cli) fn chromium_entry(reply: &Value) -> Option<ProcessEntry<'_>> {
    reply
        .get("chromium")
        .filter(|part| part.is_object())
        .map(|part| ProcessEntry::of(part, "chromium"))
}

pub(super) struct Collected {
    pub bundle: Bundle,
    /// The processes whose file is not in the bundle, and why.
    pub not_copied: Vec<Value>,
}

/// Copies each ring and the Chromium JSON the stop reply names into `out`. `chromium_asked`: the
/// record asked for Chromium, so a reply without its part is reported.
pub(super) fn collect(
    stop: &Value,
    out: &Path,
    chromium_asked: bool,
) -> Result<Collected, Failure> {
    let rings_dir = out.join(RINGS_DIR);
    cmux_blocking::fs::create_dir_all(&rings_dir)
        .map_err(|error| super::write_failure(out, &error))?;
    let mut bundle =
        Bundle { dir: out.to_owned(), remotes: Vec::new(), rings: Vec::new(), chromium: None };
    let mut not_copied = Vec::new();
    let skipped = |role: &str, pid: Option<u64>, reason: &str| json!({ "role": role, "pid": pid, "reason": reason });
    for entry in process_entries(stop) {
        let Some(source) = entry.ring.map(Path::new) else {
            not_copied.push(skipped(entry.role, entry.pid, entry.missing()));
            continue;
        };
        let Some(name) = source.file_name() else {
            not_copied.push(skipped(entry.role, entry.pid, "bad_ring_path"));
            continue;
        };
        let target = unused(&rings_dir, name);
        match cmux_blocking::fs::copy(source, &target) {
            Ok(_) => bundle.rings.push(RingFile {
                role: entry.role.to_owned(),
                pid: entry.pid,
                machine: RingMachine::Local,
                path: target,
            }),
            Err(error) => not_copied.push(skipped(entry.role, entry.pid, &error.to_string())),
        }
    }
    match chromium_entry(stop) {
        Some(ProcessEntry { ring: Some(source), .. }) => {
            let target = out.join(CHROMIUM_FILE);
            match cmux_blocking::fs::copy(source, &target) {
                Ok(_) => {
                    let offset_ns = stop.pointer("/chromium/offset_ns").and_then(Value::as_i64);
                    bundle.chromium = Some(ChromiumFile { path: target, offset_ns });
                }
                Err(error) => not_copied.push(skipped("chromium", None, &error.to_string())),
            }
        }
        Some(entry) => not_copied.push(skipped("chromium", None, entry.missing())),
        None if chromium_asked => not_copied.push(skipped("chromium", None, "no_reply")),
        None => {}
    }
    Ok(Collected { bundle, not_copied })
}

/// `dir/name`, or `dir/<n>-name` when two processes' rings share a name.
fn unused(dir: &Path, name: &std::ffi::OsStr) -> PathBuf {
    let plain = dir.join(name);
    if cmux_blocking::fs::metadata(&plain).is_err() {
        return plain;
    }
    (1..)
        .map(|n| dir.join(format!("{n}-{}", name.to_string_lossy())))
        .find(|path| cmux_blocking::fs::metadata(path).is_err())
        .unwrap_or(plain)
}

fn relative(dir: &Path, path: &Path) -> String {
    path.strip_prefix(dir).unwrap_or(path).display().to_string()
}

impl Bundle {
    /// The manifest's `remotes`, `rings` and `chromium`, with paths relative to the bundle.
    pub(super) fn manifest_fields(&self) -> [(&'static str, Value); 3] {
        let rings = self.rings.iter().map(|ring| {
            let machine = match ring.machine {
                RingMachine::Local => json!("local"),
                RingMachine::Remote(index) => json!({ "remote": index }),
            };
            json!({
                "role": ring.role,
                "pid": ring.pid,
                "machine": machine,
                "file": relative(&self.dir, &ring.path),
            })
        });
        let remotes = self.remotes.iter().map(|remote| {
            json!({
                "name": remote.name,
                "offset_ns": remote.offset_ns,
                "error_bound_ns": remote.error_bound_ns,
            })
        });
        let chromium = self.chromium.as_ref().map(|chromium| {
            json!({ "file": relative(&self.dir, &chromium.path), "offset_ns": chromium.offset_ns })
        });
        [
            ("remotes", Value::Array(remotes.collect())),
            ("rings", Value::Array(rings.collect())),
            ("chromium", chromium.unwrap_or(Value::Null)),
        ]
    }

    /// The bundle `dir/manifest.json` describes. Every file it names must be inside `dir`.
    pub(super) fn read(dir: &Path) -> Result<Bundle, String> {
        let bytes = cmux_blocking::fs::read(dir.join(MANIFEST_FILE))
            .map_err(|error| format!("{MANIFEST_FILE}: {error}"))?;
        let manifest: Value =
            serde_json::from_slice(&bytes).map_err(|error| format!("{MANIFEST_FILE}: {error}"))?;
        Self::from_manifest(dir, &manifest)
    }

    fn from_manifest(dir: &Path, manifest: &Value) -> Result<Bundle, String> {
        let file = |value: &Value| -> Result<PathBuf, String> {
            let name = value.get("file").and_then(Value::as_str).ok_or("a file has no name")?;
            let path = Path::new(name);
            if !path.components().all(|part| matches!(part, Component::Normal(_))) {
                return Err(format!("{name} is not inside the bundle"));
            }
            Ok(dir.join(path))
        };
        let list =
            |key: &str| manifest.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
        let remotes = list("remotes")
            .iter()
            .map(|remote| {
                Some(RemoteMachine {
                    name: remote.get("name")?.as_str()?.to_owned(),
                    offset_ns: remote.get("offset_ns")?.as_i64()?,
                    error_bound_ns: remote.get("error_bound_ns")?.as_u64()?,
                })
            })
            .collect::<Option<Vec<_>>>()
            .ok_or("a remote machine has no name, offset_ns or error_bound_ns")?;
        let rings = list("rings")
            .iter()
            .map(|ring| {
                let machine = match ring.get("machine") {
                    None => RingMachine::Local,
                    Some(machine) if machine == "local" => RingMachine::Local,
                    Some(machine) => match machine.get("remote").and_then(Value::as_u64) {
                        Some(index) if (index as usize) < remotes.len() => {
                            RingMachine::Remote(index as usize)
                        }
                        _ => return Err(format!("a ring names an unknown machine {machine}")),
                    },
                };
                Ok(RingFile {
                    role: ring.get("role").and_then(Value::as_str).unwrap_or("unknown").to_owned(),
                    pid: ring.get("pid").and_then(Value::as_u64),
                    machine,
                    path: file(ring)?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        let chromium = match manifest.get("chromium").filter(|chromium| !chromium.is_null()) {
            Some(chromium) => Some(ChromiumFile {
                path: file(chromium)?,
                offset_ns: chromium.get("offset_ns").and_then(Value::as_i64),
            }),
            None => None,
        };
        Ok(Bundle { dir: dir.to_owned(), remotes, rings, chromium })
    }
}
