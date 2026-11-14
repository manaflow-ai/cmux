//! `cmux theme` for theme files (`~/.config/cmux/themes/NAME.json`, the
//! whole look of the app as one dotfile; `cmux_config::theme_file`). The
//! reads, checks and writes run in process, so they work with cmux quit; the
//! running app reloads a saved file at once. Picking a file (`use`, `reset`
//! with no key) is a settings write, sent as `cmux settings` sends it.
//!
//! - `list`: the theme files, the active one marked.
//! - `path [NAME]`: where a theme file is (default: the active one).
//! - `get [KEY] [--theme NAME]`: what the file sets, or one key of it.
//! - `set KEY VALUE [--theme NAME]`: one look value into the file, checked
//!   first; comments and the file's layout are kept.
//! - `reset [KEY] [--theme NAME]`: takes KEY out of the file; with no KEY,
//!   unsets `appearance.themeFile`, back to the stock look.
//! - `export [--save NAME [--use] | --output FILE] [--name TITLE]`: the
//!   current look as a theme file. Applying it changes nothing.
//! - `import FILE [--name N] [--replace] [--use]`: a cmux theme file (or a
//!   16-color scheme, see `theme_scheme`) into the themes folder.
//! - `use NAME`: makes NAME the active theme file.
//! - `check [NAME|FILE]`: the problems the app would report, as
//!   `FILE:LINE: key: message`; exit 1 when there are any.
//! - `schema [--install]`: the theme file JSON Schema (`--install` writes
//!   `themes/.schema.json`, which `export` points `$schema` at).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cmux_config::domains::Domains;
use cmux_config::keypath::{dotted, key_path};
use cmux_config::schema::{Schema, accepts};
use cmux_config::theme_file::render::{RenderOptions, render};
use cmux_config::theme_file::{self, ThemeFile};
use cmux_config::value::value_at;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

pub(super) const USAGE: &str = "\
cmux theme: the whole look of cmux as one file, ~/.config/cmux/themes/NAME.json.
  cmux theme list                                   the theme files, the active one marked
  cmux theme export [--save NAME [--use] | --output FILE] [--name TITLE]
      the current look as a theme file (applying it changes nothing)
  cmux theme use NAME                               make NAME the active look; it reloads on save
  cmux theme get [KEY] [--theme NAME]               what the active (or named) file sets
  cmux theme set KEY VALUE [--theme NAME]           one look value, checked first
  cmux theme reset [KEY] [--theme NAME]             take KEY out; with no KEY, back to the stock look
  cmux theme import FILE [--name N] [--replace] [--use]   a theme file into the themes folder
  cmux theme check [NAME|FILE]                      problems as FILE:LINE: key: message
  cmux theme schema [--install]                     the theme file JSON Schema
  cmux theme path [NAME]";

/// The verbs this module answers; the rest of `cmux theme` is `theme_scheme`.
pub(super) const VERBS: &[&str] =
    &["list", "path", "get", "set", "reset", "use", "check", "schema"];

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Request {
    List,
    Path { name: Option<String> },
    Get { key: Option<String>, theme: Option<String> },
    Set { key: String, value: Value, theme: Option<String> },
    Reset { key: Option<String>, theme: Option<String> },
    Export { save: Option<String>, output: Option<PathBuf>, title: Option<String>, activate: bool },
    Import { file: PathBuf, name: Option<String>, replace: bool, activate: bool },
    Use { name: String },
    Check { target: Option<String> },
    Schema { install: bool },
}

/// Whether `file` is a cmux theme file rather than a 16-color scheme: a
/// JSON object whose keys are all theme file keys or look settings.
pub(super) fn is_theme_file(file: &Path) -> bool {
    if !file.extension().is_some_and(|ext| ext.eq_ignore_ascii_case("json")) {
        return false;
    }
    let Ok(text) = std::fs::read_to_string(file) else { return false };
    let Ok(Value::Object(members)) = cmux_config::jsonc::parse(&text) else { return false };
    let schema = Schema::embedded();
    !members.is_empty()
        && members.keys().all(|key| {
            theme_file::RESERVED_KEYS.contains(&key.as_str())
                || schema.row(key).is_some_and(theme_file::is_look)
                || theme_file::look_rows(schema).any(|row| row.path.first() == Some(key))
        })
}

/// A command-line value: JSON when it parses (`true`, `0.8`, `"x"`, `{..}`), else the text.
fn value_arg(text: &str) -> Value {
    serde_json::from_str(text).unwrap_or_else(|_| Value::String(text.to_string()))
}

pub(super) fn parse(args: &[String]) -> Result<Request, String> {
    let usage = || USAGE.to_owned();
    let (verb, rest) = args.split_first().ok_or_else(usage)?;
    let mut positional: Vec<String> = Vec::new();
    let (mut theme, mut save, mut output, mut title, mut name) = (None, None, None, None, None);
    let (mut activate, mut replace, mut install) = (false, false, false);
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let mut next = || words.next().cloned().ok_or_else(usage);
        match word.as_str() {
            "--theme" => theme = Some(next()?),
            "--save" => save = Some(next()?),
            "--output" | "-o" => output = Some(PathBuf::from(next()?)),
            "--name" if verb == "export" => title = Some(next()?),
            "--name" => name = Some(next()?),
            "--use" => activate = true,
            "--replace" => replace = true,
            "--install" => install = true,
            "-h" | "--help" => return Err(usage()),
            flag if flag.starts_with("--") => {
                return Err(format!("unknown option {flag}\n\n{USAGE}"));
            }
            _ => positional.push(word.clone()),
        }
    }
    let check_name = |name: &str| {
        if theme_file::is_valid_name(name) {
            Ok(())
        } else {
            Err(format!(
                "{name:?} is not a theme file name: a plain name such as tokyo, for themes/tokyo.json"
            ))
        }
    };
    for name in [&theme, &save, &name].into_iter().flatten() {
        check_name(name)?;
    }
    Ok(match (verb.as_str(), positional.as_slice()) {
        ("list", []) => Request::List,
        ("path", []) => Request::Path { name: theme },
        ("path", [one]) => Request::Path { name: Some(one.clone()) },
        ("get", []) => Request::Get { key: None, theme },
        ("get", [key]) => Request::Get { key: Some(key.clone()), theme },
        ("set", [key, value]) => Request::Set { key: key.clone(), value: value_arg(value), theme },
        ("reset", []) => Request::Reset { key: None, theme },
        ("reset", [key]) => Request::Reset { key: Some(key.clone()), theme },
        ("export", [])
            if !(save.is_some() && output.is_some()) && (!activate || save.is_some()) =>
        {
            Request::Export { save, output, title, activate }
        }
        ("import", [file]) => Request::Import { file: file.into(), name, replace, activate },
        ("use", [one]) => {
            check_name(one)?;
            Request::Use { name: one.clone() }
        }
        ("check", []) => Request::Check { target: None },
        ("check", [one]) => Request::Check { target: Some(one.clone()) },
        ("schema", []) => Request::Schema { install },
        _ => return Err(usage()),
    })
}

/// Where the app reads: the settings file and the themes folder beside it.
struct Paths {
    settings: PathBuf,
    config_dir: PathBuf,
}

impl Paths {
    fn current() -> Paths {
        let settings = cmux_config::config_path();
        let config_dir = settings.parent().map(Path::to_path_buf).unwrap_or_default();
        Paths { settings, config_dir }
    }

    /// The settings file as written (`{}` when missing or unreadable).
    fn settings_root(&self) -> Value {
        std::fs::read_to_string(&self.settings)
            .ok()
            .and_then(|text| cmux_config::jsonc::parse(&text).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| json!({}))
    }

    fn themes(&self) -> PathBuf {
        theme_file::folder(&self.config_dir)
    }

    fn file(&self, name: &str) -> PathBuf {
        theme_file::path(&self.config_dir, name)
    }
}

fn fail(global: &GlobalArgs, code: &str, message: String) -> i32 {
    super::wire::print_local_error(&json!({ "code": code, "message": message }), global.output, 1)
}

fn ok(global: &GlobalArgs, value: &Value, text: &str) -> i32 {
    if matches!(global.output, OutputMode::Json | OutputMode::JsonLines) {
        return super::wire::print_local_success(value, global.output);
    }
    println!("{text}");
    0
}

/// The file a verb works on: `--theme`, else the active one.
fn target(global: &GlobalArgs, paths: &Paths, theme: Option<String>) -> Result<String, i32> {
    if let Some(theme) = theme {
        return Ok(theme);
    }
    theme_file::name_in(&paths.settings_root()).map(str::to_string).ok_or_else(|| {
        fail(
            global,
            "theme.none",
            "no theme file is active: `cmux theme export --save NAME --use` writes the current look as one and picks it"
                .to_string(),
        )
    })
}

fn read(paths: &Paths, name: &str, text: Option<&str>) -> ThemeFile {
    let base = paths.settings_root();
    let source = match text {
        Some(text) => Some(Ok(text.to_string())),
        None => theme_file::source(&paths.config_dir, name, None),
    };
    ThemeFile::read(
        name,
        source.as_ref().map(|result| result.as_deref().map_err(Clone::clone)),
        &base,
        Some(&paths.themes()),
        Schema::embedded(),
        &Domains::default(),
    )
}

fn diagnostics_json(file: &ThemeFile) -> Value {
    Value::Array(
        file.diagnostics
            .iter()
            .map(|d| json!({ "kind": d.kind, "path": d.path, "file": d.file, "line": d.line, "message": d.message, "text": d.display() }))
            .collect(),
    )
}

fn print_problems(file: &ThemeFile) {
    for diagnostic in &file.diagnostics {
        eprintln!("{}", diagnostic.display());
    }
}

/// Sends `cmux settings ARGS...` with this run's global options (`prefix`,
/// the words before `theme`).
fn settings(global: &GlobalArgs, prefix: &[String], args: &[&str]) -> i32 {
    let mut command: Vec<String> = prefix.to_vec();
    if matches!(global.output, OutputMode::Json | OutputMode::JsonLines)
        && !command.iter().any(|w| w == "--json")
    {
        command.push("--json".to_string());
    }
    command.push("settings".to_string());
    command.extend(args.iter().map(|arg| (*arg).to_string()));
    super::run(&command, "")
}

pub(super) fn run(global: &GlobalArgs, prefix: &[String], request: Request) -> i32 {
    let paths = Paths::current();
    match request {
        Request::List => {
            let active = theme_file::name_in(&paths.settings_root()).map(str::to_string);
            let names = theme_file::names(&paths.config_dir, None);
            let text = names
                .iter()
                .map(|name| {
                    format!("{} {name}", if Some(name) == active.as_ref() { "*" } else { " " })
                })
                .collect::<Vec<_>>()
                .join("\n");
            ok(
                global,
                &json!({ "themes": names, "active": active, "folder": paths.themes() }),
                &text,
            )
        }
        Request::Path { name } => {
            match name.map(Ok).unwrap_or_else(|| target(global, &paths, None)) {
                Ok(name) => {
                    let path = paths.file(&name);
                    ok(
                        global,
                        &json!({ "name": name, "path": path, "exists": path.is_file() }),
                        &path.display().to_string(),
                    )
                }
                Err(code) => code,
            }
        }
        Request::Get { key, theme } => {
            let name = match target(global, &paths, theme) {
                Ok(name) => name,
                Err(code) => return code,
            };
            let file = read(&paths, &name, None);
            print_problems(&file);
            if !file.is_loaded {
                return 1;
            }
            let applied = file.applied(&json!({}), &BTreeSet::new());
            match key {
                Some(key) => match value_at(&applied, &key_path(&key)) {
                    Some(value) => ok(
                        global,
                        &json!({ "key": key, "value": value, "theme": name }),
                        &value.to_string(),
                    ),
                    None => fail(
                        global,
                        "resource.not_found",
                        format!("themes/{name}.json does not set {key}"),
                    ),
                },
                None => {
                    let values: serde_json::Map<String, Value> = file
                        .values
                        .iter()
                        .map(|(path, value)| (dotted(path), value.clone()))
                        .collect();
                    let text = values
                        .iter()
                        .map(|(key, value)| format!("{key} = {value}"))
                        .collect::<Vec<_>>()
                        .join("\n");
                    ok(
                        global,
                        &json!({ "theme": name, "values": values, "diagnostics": diagnostics_json(&file) }),
                        &text,
                    )
                }
            }
        }
        Request::Set { key, value, theme } => {
            let name = match target(global, &paths, theme) {
                Ok(name) => name,
                Err(code) => return code,
            };
            set(global, &paths, &name, &key, value)
        }
        Request::Reset { key: None, .. } => {
            settings(global, prefix, &["reset", theme_file::SETTING_KEY])
        }
        Request::Reset { key: Some(key), theme } => {
            let name = match target(global, &paths, theme) {
                Ok(name) => name,
                Err(code) => return code,
            };
            reset(global, &paths, &name, &key)
        }
        Request::Export { save, output, title, activate } => {
            let root = current_look(&paths);
            let title = title.or_else(|| save.clone()).unwrap_or_else(|| "My look".to_string());
            let text = render(
                &root,
                Schema::embedded(),
                &Domains::default(),
                &RenderOptions { name: &title, description: "" },
            );
            if let Some(name) = save {
                let path = paths.file(&name);
                if path.exists() {
                    return fail(
                        global,
                        "theme.exists",
                        format!("{} exists; pick another name", path.display()),
                    );
                }
                if let Err(code) =
                    write(global, &path, &text).and_then(|()| install_schema(global, &paths))
                {
                    return code;
                }
                if activate {
                    return settings(global, prefix, &["set", theme_file::SETTING_KEY, &name]);
                }
                return ok(
                    global,
                    &json!({ "name": name, "path": path }),
                    &path.display().to_string(),
                );
            }
            if let Some(output) = output {
                return match write(global, &output, &text) {
                    Ok(()) => ok(global, &json!({ "path": output }), &output.display().to_string()),
                    Err(code) => code,
                };
            }
            print!("{text}");
            0
        }
        Request::Import { file, name, replace, activate } => {
            let name = name.unwrap_or_else(|| {
                file.file_stem().map(|stem| stem.to_string_lossy().into_owned()).unwrap_or_default()
            });
            if !theme_file::is_valid_name(&name) {
                return fail(
                    global,
                    "validation.invalid",
                    format!("{name:?} is not a theme file name; pass --name"),
                );
            }
            let text = match std::fs::read_to_string(&file) {
                Ok(text) => text,
                Err(error) => return fail(global, "io", format!("{}: {error}", file.display())),
            };
            let checked = read(&paths, &name, Some(&text));
            print_problems(&checked);
            if checked.is_unparsable {
                return 1;
            }
            let path = paths.file(&name);
            if path.exists() && !replace {
                return fail(
                    global,
                    "theme.exists",
                    format!("{} exists; --replace overwrites it", path.display()),
                );
            }
            if let Err(code) = write(global, &path, &text) {
                return code;
            }
            if activate {
                return settings(global, prefix, &["set", theme_file::SETTING_KEY, &name]);
            }
            ok(
                global,
                &json!({ "name": name, "path": path, "diagnostics": diagnostics_json(&checked) }),
                &path.display().to_string(),
            )
        }
        Request::Use { name } => {
            if theme_file::source(&paths.config_dir, &name, None).is_none() {
                return fail(
                    global,
                    "resource.not_found",
                    format!("there is no theme file {}", paths.file(&name).display()),
                );
            }
            settings(global, prefix, &["set", theme_file::SETTING_KEY, &name])
        }
        Request::Check { target: spec } => {
            let (name, text) = match spec {
                Some(spec) if spec.contains('/') || spec.ends_with(".json") => {
                    let path = PathBuf::from(&spec);
                    let name = path
                        .file_stem()
                        .map(|s| s.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    match std::fs::read_to_string(&path) {
                        Ok(text) => (name, Some(text)),
                        Err(error) => return fail(global, "io", format!("{spec}: {error}")),
                    }
                }
                spec => match target(global, &paths, spec) {
                    Ok(name) => (name, None),
                    Err(code) => return code,
                },
            };
            let file = read(&paths, &name, text.as_deref());
            let problems: Vec<String> = file.diagnostics.iter().map(|d| d.display()).collect();
            if matches!(global.output, OutputMode::Json | OutputMode::JsonLines) {
                super::wire::print_local_success(
                    &json!({ "theme": name, "ok": problems.is_empty(), "keys": file.keys(), "diagnostics": diagnostics_json(&file) }),
                    global.output,
                );
            } else if problems.is_empty() {
                println!("themes/{name}.json: no problems ({} look keys)", file.values.len());
            } else {
                println!("{}", problems.join("\n"));
            }
            i32::from(!problems.is_empty())
        }
        Request::Schema { install: false } => {
            let schema = Schema::embedded().theme_file_json_schema(theme_file::is_look);
            println!("{}", serde_json::to_string_pretty(&schema).unwrap_or_default());
            0
        }
        Request::Schema { install: true } => match install_schema(global, &paths) {
            Ok(()) => {
                let path = paths.themes().join(theme_file::SCHEMA_FILE_NAME);
                ok(global, &json!({ "path": path }), &path.display().to_string())
            }
            Err(code) => code,
        },
    }
}

/// The look the app shows now, as far as files say: the settings file with
/// the active theme file over it (managed values aside).
fn current_look(paths: &Paths) -> Value {
    let root = paths.settings_root();
    let Some(name) = theme_file::name_in(&root).map(str::to_string) else { return root };
    let file = read(paths, &name, None);
    let mut look = file.applied(&root, &BTreeSet::new());
    // The exported file is the look itself, not a pointer to another file.
    if let Some(appearance) = look.get_mut("appearance").and_then(Value::as_object_mut) {
        appearance.remove("themeFile");
    }
    look
}

fn write(global: &GlobalArgs, path: &Path, text: &str) -> Result<(), i32> {
    if let Some(parent) = path.parent()
        && let Err(error) = std::fs::create_dir_all(parent)
    {
        return Err(fail(global, "io", format!("{}: {error}", parent.display())));
    }
    cmux_config::fsio::write_atomic(path, text.as_bytes())
        .map_err(|error| fail(global, "io", format!("{}: {error}", path.display())))
}

fn install_schema(global: &GlobalArgs, paths: &Paths) -> Result<(), i32> {
    let schema = Schema::embedded().theme_file_json_schema(theme_file::is_look);
    let text = serde_json::to_string_pretty(&schema).unwrap_or_default() + "\n";
    write(global, &paths.themes().join(theme_file::SCHEMA_FILE_NAME), &text)
}

fn existing_text(global: &GlobalArgs, paths: &Paths, name: &str) -> Result<String, i32> {
    match theme_file::source(&paths.config_dir, name, None) {
        Some(Ok(text)) => Ok(text),
        Some(Err(error)) => Err(fail(global, "io", format!("themes/{name}.json: {error}"))),
        None => Err(fail(
            global,
            "resource.not_found",
            format!("there is no theme file {}", paths.file(name).display()),
        )),
    }
}

fn set(global: &GlobalArgs, paths: &Paths, name: &str, key: &str, value: Value) -> i32 {
    let schema = Schema::embedded();
    let Some(row) = schema.row(key) else {
        return fail(global, "validation.invalid", format!("{key} is not a cmux setting"));
    };
    if !theme_file::is_look(row) {
        return fail(
            global,
            "validation.invalid",
            format!("{key}: a theme file sets only look settings"),
        );
    }
    if let Err(refusal) = accepts(row, &value, &Domains::default()) {
        return fail(global, "validation.invalid", refusal.to_string());
    }
    let text = match existing_text(global, paths, name) {
        Ok(text) => text,
        Err(code) => return code,
    };
    // Where the file already writes the key (nested or dotted), else dotted at the top.
    let parsed = cmux_config::jsonc::parse(&text).unwrap_or_default();
    let path = if value_at(&parsed, &row.path).is_some() {
        row.path.clone()
    } else {
        vec![row.key.clone()]
    };
    let edited = match cmux_config::jsonc::set(&text, &path, &value) {
        Ok(edited) => edited,
        Err(error) => {
            return fail(global, "validation.invalid", format!("themes/{name}.json: {error}"));
        }
    };
    let file = read(paths, name, Some(&edited));
    if let Some(problem) = file.diagnostics.iter().find(|d| d.path == row.key) {
        return fail(global, "validation.invalid", problem.display());
    }
    if let Err(code) = write(global, &paths.file(name), &edited) {
        return code;
    }
    ok(
        global,
        &json!({ "theme": name, "key": key, "value": value }),
        &format!("themes/{name}.json: {key} = {value}"),
    )
}

fn reset(global: &GlobalArgs, paths: &Paths, name: &str, key: &str) -> i32 {
    let mut text = match existing_text(global, paths, name) {
        Ok(text) => text,
        Err(code) => return code,
    };
    let mut removed = false;
    for path in [vec![key.to_string()], key_path(key)] {
        let parsed = cmux_config::jsonc::parse(&text).unwrap_or_default();
        if value_at(&parsed, &path).is_some()
            && let Ok(edited) = cmux_config::jsonc::remove(&text, &path)
        {
            text = edited;
            removed = true;
        }
    }
    if !removed {
        return fail(
            global,
            "resource.not_found",
            format!("themes/{name}.json does not set {key}"),
        );
    }
    if let Err(code) = write(global, &paths.file(name), &text) {
        return code;
    }
    ok(global, &json!({ "theme": name, "key": key }), &format!("themes/{name}.json: {key} removed"))
}

#[cfg(test)]
mod tests;
