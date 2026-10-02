//! Catalog-driven argument parsing: flags come from the op's params
//! (`--add-labels x` for `add_labels`), the positional param takes the first
//! bare word, ids marked `generate` are minted when omitted.

use std::io::Read;

use cmux_tasks_core::catalog::{Entry, Param, Ty};
use serde_json::{Map, Value, json};

use crate::owner::mint;

#[derive(Debug, Default)]
pub struct Global {
    pub json: bool,
    pub team: Option<String>,
    pub data: Option<std::path::PathBuf>,
    pub key: Option<String>,
    pub key_prefix: Option<String>,
    pub help: bool,
    /// `task watch`: stop after this many events.
    pub count: Option<u64>,
    /// `task watch`: stop after this many seconds.
    pub timeout: Option<u64>,
}

/// Split global flags from the rest.
pub fn split_global(args: &[String]) -> Result<(Global, Vec<String>), String> {
    let mut global = Global::default();
    let mut rest = Vec::new();
    let mut iter = args.iter().peekable();
    while let Some(arg) = iter.next() {
        let mut value_of = |name: &str| -> Result<String, String> {
            if let Some(v) = arg.strip_prefix(&format!("--{name}=")) {
                return Ok(v.to_owned());
            }
            iter.next().cloned().ok_or_else(|| format!("--{name} needs a value"))
        };
        match arg.as_str() {
            "--json" => global.json = true,
            "-h" | "--help" => global.help = true,
            a if a == "--team" || a.starts_with("--team=") => global.team = Some(value_of("team")?),
            a if a == "--data" || a.starts_with("--data=") => {
                global.data = Some(value_of("data")?.into())
            }
            a if a == "--idempotency-key" || a.starts_with("--idempotency-key=") => {
                global.key = Some(value_of("idempotency-key")?)
            }
            a if a == "--key-prefix" || a.starts_with("--key-prefix=") => {
                global.key_prefix = Some(value_of("key-prefix")?)
            }
            a if a == "--count" || a.starts_with("--count=") => {
                global.count =
                    Some(value_of("count")?.parse().map_err(|_| "--count takes a number")?)
            }
            a if a == "--timeout" || a.starts_with("--timeout=") => {
                global.timeout =
                    Some(value_of("timeout")?.parse().map_err(|_| "--timeout takes seconds")?)
            }
            _ => rest.push(arg.clone()),
        }
    }
    Ok((global, rest))
}

fn flag_name(param: &Param) -> String {
    param.name.replace('_', "-")
}

fn read_stdin() -> Result<String, String> {
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).map_err(|e| format!("stdin: {e}"))?;
    Ok(text)
}

fn convert(param: &Param, raw: &str) -> Result<Value, String> {
    let flag = flag_name(param);
    Ok(match param.ty {
        Ty::Str | Ty::TaskRef | Ty::Id { .. } => {
            if raw == "-" && matches!(param.name, "description" | "body" | "prompt") {
                json!(read_stdin()?)
            } else if let Some(path) = raw
                .strip_prefix('@')
                .filter(|_| matches!(param.name, "description" | "body" | "prompt"))
            {
                json!(std::fs::read_to_string(path).map_err(|e| format!("--{flag} {path}: {e}"))?)
            } else {
                json!(raw)
            }
        }
        Ty::Bool => match raw {
            "true" | "yes" | "1" => json!(true),
            "false" | "no" | "0" => json!(false),
            _ => return Err(format!("--{flag} takes true or false")),
        },
        Ty::U32 | Ty::U64 => {
            json!(raw.parse::<u64>().map_err(|_| format!("--{flag} takes a number"))?)
        }
        Ty::I64 => json!(raw.parse::<i64>().map_err(|_| format!("--{flag} takes a number"))?),
        Ty::Enum(values) => {
            let normalized = raw.replace('-', "_");
            if !values.contains(&normalized.as_str()) {
                return Err(format!("--{flag} takes one of: {}", values.join(", ")));
            }
            json!(normalized)
        }
        Ty::Json => {
            let text = if raw == "-" {
                read_stdin()?
            } else if let Some(path) = raw.strip_prefix('@') {
                std::fs::read_to_string(path).map_err(|e| format!("--{flag} {path}: {e}"))?
            } else {
                raw.to_owned()
            };
            serde_json::from_str(&text).map_err(|e| format!("--{flag}: {e}"))?
        }
    })
}

/// Build the op params from the words after the CLI path.
pub fn params(entry: &Entry, words: &[String]) -> Result<Value, String> {
    let mut out = Map::new();
    let mut iter = words.iter();
    while let Some(word) = iter.next() {
        if let Some(flag) = word.strip_prefix("--") {
            let (name, inline) = match flag.split_once('=') {
                Some((n, v)) => (n, Some(v.to_owned())),
                None => (flag, None),
            };
            let param = entry
                .params
                .iter()
                .find(|p| flag_name(p) == name)
                .ok_or_else(|| format!("unknown flag --{name} for `{}`", entry.cli))?;
            let raw = match (param.ty, inline) {
                (_, Some(v)) => v,
                (Ty::Bool, None) => "true".to_owned(),
                (_, None) => {
                    iter.next().cloned().ok_or_else(|| format!("--{name} needs a value"))?
                }
            };
            let value = convert(param, &raw)?;
            if param.repeated {
                out.entry(param.name)
                    .or_insert_with(|| json!([]))
                    .as_array_mut()
                    .expect("array")
                    .push(value);
            } else if out.insert(param.name.to_owned(), value).is_some() {
                return Err(format!("--{name} given twice"));
            }
        } else {
            let param = entry
                .params
                .iter()
                .find(|p| p.positional && !out.contains_key(p.name))
                .ok_or_else(|| format!("unexpected argument `{word}` for `{}`", entry.cli))?;
            out.insert(param.name.to_owned(), convert(param, word)?);
        }
    }
    for param in entry.params {
        if out.contains_key(param.name) {
            continue;
        }
        if let Ty::Id { prefix, generate: true } = param.ty {
            out.insert(param.name.to_owned(), json!(mint(prefix)));
        } else if param.required {
            let shown = if param.positional {
                param.name.to_uppercase()
            } else {
                format!("--{}", flag_name(param))
            };
            return Err(format!("`{}` needs {shown}", entry.cli));
        }
    }
    Ok(Value::Object(out))
}

/// Help text for one op, generated from its params.
pub fn usage(entry: &Entry) -> String {
    let positional = entry
        .params
        .iter()
        .find(|p| p.positional)
        .map(|p| format!(" {}", p.name.to_uppercase()))
        .unwrap_or_default();
    let mut out = format!("cmux {}{positional} [flags]\n  {}\n", entry.cli, entry.docs);
    for p in entry.params.iter().filter(|p| !p.positional) {
        let value = match p.ty {
            Ty::Bool => String::new(),
            Ty::Enum(values) => format!(" {}", values.join("|")),
            Ty::U32 | Ty::U64 | Ty::I64 => " N".to_owned(),
            Ty::Json => " JSON|@FILE|-".to_owned(),
            _ => " VALUE".to_owned(),
        };
        let many = if p.repeated { " (repeatable)" } else { "" };
        let req = if p.required && !matches!(p.ty, Ty::Id { generate: true, .. }) {
            " (required)"
        } else {
            ""
        };
        out.push_str(&format!("  --{}{value}  {}{many}{req}\n", flag_name(p), p.doc));
    }
    out
}
