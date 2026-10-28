//! The daemon side of the oracle's config suite: reads every
//! file of `tests/oracle/corpus/config` the way cmux-config does and prints
//! one JSONL dump line per file. `OracleConfigDump` (Swift) prints the same
//! lines for the app; `scripts/cmux-next/oracle/gen_config.py diff` compares
//! them. The line format is in gen_config.py's docstring.
//!
//! cargo run -p cmux-config --example oracle_effective -- --corpus DIR [--out FILE]

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use cmux_config::diagnostics::DiagnosticKind;
use cmux_config::jsonc;
use cmux_config::keybindings::{bare, stroke};
use cmux_config::schema::{accepts, effective_value, retired_keys};
use cmux_config::value::value_at;
use cmux_config::{
    Domains, EffectiveSettings, ManagedPreferences, ManagedSource, Schema, TeamPolicyLayer,
};
use serde_json::{Map, Value, json};

/// Why a run stops: bad arguments, an unreadable corpus or a broken envelope.
#[derive(Debug)]
enum DumpError {
    Usage(String),
    Io(PathBuf, io::Error),
    Envelope(String, String),
}

impl std::fmt::Display for DumpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DumpError::Usage(message) => write!(f, "{message}"),
            DumpError::Io(path, error) => write!(f, "{}: {error}", path.display()),
            DumpError::Envelope(file, message) => write!(f, "{file}: {message}"),
        }
    }
}

struct Options {
    corpus: PathBuf,
    out: Option<PathBuf>,
}

fn options() -> Result<Options, DumpError> {
    let mut args = std::env::args().skip(1);
    let (mut corpus, mut out) = (None, None);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--corpus" => corpus = args.next().map(PathBuf::from),
            "--out" => out = args.next().map(PathBuf::from),
            _ => return Err(DumpError::Usage(format!("unknown argument {arg}"))),
        }
    }
    let corpus = corpus.ok_or_else(|| {
        DumpError::Usage("usage: oracle_effective --corpus DIR [--out FILE]".into())
    })?;
    Ok(Options { corpus, out })
}

/// Every `.jsonc` file under `root`, as sorted paths relative to it.
fn corpus_files(root: &Path) -> Result<Vec<String>, DumpError> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let entries = fs::read_dir(&dir).map_err(|error| DumpError::Io(dir.clone(), error))?;
        for entry in entries {
            let path = entry.map_err(|error| DumpError::Io(dir.clone(), error))?.path();
            if path.is_dir() {
                pending.push(path);
            } else if path.extension().is_some_and(|ext| ext == "jsonc")
                && let Ok(rel) = path.strip_prefix(root)
            {
                let parts: Vec<String> = rel
                    .components()
                    .map(|c| c.as_os_str().to_string_lossy().into_owned())
                    .collect();
                found.push(parts.join("/"));
            }
        }
    }
    found.sort();
    Ok(found)
}

/// The inputs of one merge: the file text and the managed layers.
struct Inputs {
    text: String,
    managed: ManagedPreferences,
    team: TeamPolicyLayer,
}

fn string_map(value: Option<&Value>) -> BTreeMap<String, Value> {
    value
        .and_then(Value::as_object)
        .map(|members| members.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
        .unwrap_or_default()
}

fn envelope(file: &str, text: &str) -> Result<Inputs, DumpError> {
    let root: Value = serde_json::from_str(text)
        .map_err(|error| DumpError::Envelope(file.into(), error.to_string()))?;
    let file_text = root
        .get("file")
        .and_then(Value::as_str)
        .ok_or_else(|| DumpError::Envelope(file.into(), "\"file\" must be a string".into()))?;
    let team = root.get("team");
    Ok(Inputs {
        text: file_text.to_string(),
        managed: ManagedPreferences {
            forced: string_map(root.get("forced")),
            recommended: string_map(root.get("recommended")),
        },
        team: TeamPolicyLayer {
            team_name: team
                .and_then(|t| t.get("name"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            defaults: string_map(team.and_then(|t| t.get("defaults"))),
            enforced: string_map(team.and_then(|t| t.get("enforced"))),
            ..TeamPolicyLayer::default()
        },
    })
}

fn source_name(source: &ManagedSource) -> String {
    match source {
        ManagedSource::Device => "mdm".into(),
        ManagedSource::Team(name) => format!("team:{name}"),
    }
}

/// The settings dump: what the app would apply for `inputs`.
fn settings_dump(inputs: &Inputs, schema: &Schema) -> Value {
    let parsed = jsonc::parse(&inputs.text).ok().filter(Value::is_object);
    let readable = parsed.is_some();
    let file_root = parsed.unwrap_or_else(|| Value::Object(Map::new()));
    let effective = EffectiveSettings::merge(&file_root, &inputs.managed, &inputs.team, schema);
    // Unpublished domains: the shape checks only, as on a host without the app.
    let domains = Domains::default();
    let mut values = Map::new();
    let mut invalid = Vec::new();
    for row in &schema.rows {
        let Some(stored) = value_at(&effective.root, &row.path) else { continue };
        values.insert(
            row.key.clone(),
            effective_value(row, &effective.root, &domains).unwrap_or(Value::Null),
        );
        if accepts(row, stored, &domains).is_err() {
            invalid.push(Value::String(row.key.clone()));
        }
    }
    let retired: Vec<Value> = retired_keys()
        .iter()
        .filter(|(key, _)| value_at(&file_root, &key.split('.').collect::<Vec<_>>()).is_some())
        .map(|(key, _)| Value::String(key.clone()))
        .collect();
    let managed: Map<String, Value> = effective
        .managed_keys
        .iter()
        .map(|(key, source)| (key.clone(), Value::String(source_name(source))))
        .collect();
    let diagnostics: Vec<Value> = effective
        .diagnostics
        .iter()
        .filter_map(|diagnostic| {
            let kind = match diagnostic.kind {
                DiagnosticKind::ManagedOverride => "managed_override",
                DiagnosticKind::ManagedConflict => "managed_conflict",
                _ => return None,
            };
            Some(json!({"kind": kind, "path": diagnostic.path, "message": diagnostic.message}))
        })
        .collect();
    json!({
        "readable": readable,
        "effective": effective.root,
        "values": values,
        "invalid": invalid,
        "retired": retired,
        "managed": managed,
        "policy": effective.policy.raw,
        "diagnostics": diagnostics,
    })
}

fn keybindings_dump(file: &str, text: &str) -> Result<Value, DumpError> {
    let root: Value = serde_json::from_str(text)
        .map_err(|error| DumpError::Envelope(file.into(), error.to_string()))?;
    let texts = |name: &str| -> Vec<String> {
        root.get(name)
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default()
    };
    let strokes: Vec<Value> = texts("strokes")
        .iter()
        .map(|s| stroke::normalize(s).map_or(Value::Null, Value::String))
        .collect();
    let bare_when: Vec<Value> =
        texts("when").iter().map(|when| Value::Bool(bare::may_bind(Some(when)))).collect();
    Ok(json!({"strokes": strokes, "bare_when": bare_when}))
}

fn dump(file: &str, text: &str, schema: &Schema) -> Result<Value, DumpError> {
    match file.split('/').next() {
        Some("keybindings") => keybindings_dump(file, text),
        Some("managed") => Ok(settings_dump(&envelope(file, text)?, schema)),
        _ => Ok(settings_dump(
            &Inputs {
                text: text.to_string(),
                managed: ManagedPreferences::default(),
                team: TeamPolicyLayer::default(),
            },
            schema,
        )),
    }
}

fn run() -> Result<(), DumpError> {
    let options = options()?;
    let schema = Schema::embedded();
    let files = corpus_files(&options.corpus)?;
    let sink: Box<dyn Write> = match &options.out {
        Some(path) => {
            Box::new(fs::File::create(path).map_err(|error| DumpError::Io(path.clone(), error))?)
        }
        None => Box::new(io::stdout().lock()),
    };
    let target = options.out.clone().unwrap_or_else(|| PathBuf::from("<stdout>"));
    let mut out = BufWriter::new(sink);
    let write = |out: &mut BufWriter<Box<dyn Write>>, line: &Value| {
        writeln!(out, "{line}").map_err(|error| DumpError::Io(target.clone(), error))
    };
    write(&mut out, &json!({"oracle_config_dump": 1, "producer": "rust"}))?;
    for file in &files {
        let path = options.corpus.join(file);
        let bytes = fs::read(&path).map_err(|error| DumpError::Io(path.clone(), error))?;
        let text = String::from_utf8_lossy(&bytes);
        write(&mut out, &json!({"file": file, "dump": dump(file, &text, schema)?}))?;
    }
    out.flush().map_err(|error| DumpError::Io(target.clone(), error))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("oracle_effective: {error}");
            ExitCode::from(2)
        }
    }
}
