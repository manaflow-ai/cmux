//! Config as code (plans/cmux-next/scripting-runtime.md section 6, phase 2):
//! the JavaScript files in `scripts/` beside the settings file, loaded into
//! one persistent script session of this daemon.
//!
//! The files define user actions (`cmux.action`), key bindings and key modes
//! (`cmux.keys`) and long-lived event handlers (`cmux.on`). A load runs
//! `init.js` first, then the other `*.js` files by name, each as one cell in
//! a fresh session, and applies only when every file ran: a broken file keeps
//! the last good load (its session, actions and keys) and reports the file,
//! line and message. Nothing loads until a client asks (`script-config-reload`,
//! which the Mac app sends when it connects), so a daemon without an app
//! (a Chief owner, a `main` session) never runs the person's handlers twice.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_app_host::script::{LogSink, ScriptError, Session, codes};
use serde_json::{Value, json};

/// How long one config file may run while it loads.
const LOAD_TIMEOUT: Duration = Duration::from_secs(10);
/// How long one user action may run. Past it the config session ends (the
/// host cannot stop one cell alone); the next reload starts a new one.
pub(crate) const ACTION_TIMEOUT: Duration = Duration::from_secs(60);
/// The file that loads first when it exists.
const INIT_FILE: &str = "init.js";
/// The folder beside the settings file.
const SCRIPTS_DIR: &str = "scripts";
/// The error code of an action run before any config loaded.
pub(crate) const NOT_LOADED: &str = "script.config_not_loaded";
/// `script-config-*`, `script-action-run` and `script-config-changed`.
pub(crate) const SCRIPT_CONFIG_CAPABILITY: &str = "script-config-v1";

/// `scripts/` beside the settings file (`CMUX_NEXT_CONFIG_FILE` moves it,
/// like keybindings.json).
pub(crate) fn scripts_dir() -> PathBuf {
    let config = cmux_config::config_path();
    config.parent().map_or_else(|| PathBuf::from(SCRIPTS_DIR), |dir| dir.join(SCRIPTS_DIR))
}

/// The files of a load, in order, and a diagnostic for each file that cannot
/// run (TypeScript until the type strip lands). `path` is the scripts folder
/// or one file; a missing folder has no files.
pub(crate) fn files(path: &Path) -> (Vec<PathBuf>, Vec<Value>) {
    if path.is_file() {
        return classify(vec![path.to_path_buf()]);
    }
    let Ok(entries) = std::fs::read_dir(path) else { return (Vec::new(), Vec::new()) };
    let mut found: Vec<PathBuf> =
        entries.filter_map(Result::ok).map(|entry| entry.path()).filter(|p| p.is_file()).collect();
    found.sort_by_key(|p| {
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
        (name != INIT_FILE, name)
    });
    classify(found)
}

fn classify(paths: Vec<PathBuf>) -> (Vec<PathBuf>, Vec<Value>) {
    let mut files = Vec::new();
    let mut diagnostics = Vec::new();
    for path in paths {
        match path.extension().and_then(|e| e.to_str()) {
            Some("js" | "mjs") => files.push(path),
            Some("ts" | "mts" | "cts" | "tsx") => diagnostics.push(json!({
                "file": path.display().to_string(),
                "line": null,
                "column": null,
                "message": "TypeScript config files are not supported yet; use .js",
            })),
            _ => {}
        }
    }
    (files, diagnostics)
}

/// One file as a cell: its own scope (top-level names of two files never
/// collide), top-level await kept. The code starts on line 2.
pub(crate) fn wrap(code: &str) -> String {
    format!("await (async () => {{\n{code}\n}})()")
}

/// A load diagnostic for `file`: the line and column of a syntax error
/// (`(line:column)` in the parser's message, less the wrapper's line).
pub(crate) fn diagnostic(file: &Path, error: &ScriptError) -> Value {
    let position = error.message.rfind('(').and_then(|open| {
        let inner = error.message[open + 1..].split(')').next()?;
        let (line, column) = inner.split_once(':')?;
        Some((line.trim().parse::<u64>().ok()?, column.trim().parse::<u64>().ok()?))
    });
    let (line, column) = match position {
        Some((line, column)) if line > 1 => (json!(line - 1), json!(column)),
        _ => (Value::Null, Value::Null),
    };
    json!({
        "file": file.display().to_string(),
        "line": line,
        "column": column,
        "code": error.code,
        "message": error.message,
    })
}

/// The live config: its session and what it defined.
struct Live {
    session: Arc<Session>,
    /// `{actions, keys, modes, removals}` from the `config` export.
    config: Value,
    files: Vec<String>,
}

#[derive(Default)]
struct State {
    live: Option<Live>,
    generation: u64,
    /// Diagnostics of the last load or check that did not apply.
    diagnostics: Vec<Value>,
}

/// The config owner of one daemon (`ScriptsSlot::config`).
#[derive(Default)]
pub(crate) struct ConfigOwner {
    state: Mutex<State>,
    /// One load or action at a time (a session runs one cell at a time).
    turn: Mutex<()>,
}

/// Starts a script session with the daemon's rights.
pub(crate) type Start<'a> = &'a dyn Fn(LogSink) -> Result<Session, ScriptError>;

/// A load's outcome before it applies.
struct Loaded {
    session: Session,
    config: Value,
    files: Vec<String>,
}

fn load(path: &Path, start: Start<'_>, log: LogSink) -> Result<Loaded, Vec<Value>> {
    let (files, mut diagnostics) = files(path);
    let session = match start(log) {
        Ok(session) => session,
        Err(error) => {
            diagnostics.push(json!({ "file": null, "line": null, "column": null, "code": error.code, "message": error.message }));
            return Err(diagnostics);
        }
    };
    for file in &files {
        let code = match std::fs::read_to_string(file) {
            Ok(code) => code,
            Err(error) => {
                diagnostics.push(json!({ "file": file.display().to_string(), "line": null, "column": null, "message": error.to_string() }));
                continue;
            }
        };
        if let Err(error) = session.eval(&wrap(&code), json!({}), LOAD_TIMEOUT) {
            diagnostics.push(diagnostic(file, &error));
            if session.is_dead() {
                break;
            }
        }
    }
    if !diagnostics.is_empty() {
        session.cancel();
        return Err(diagnostics);
    }
    match session.export("config", json!({}), LOAD_TIMEOUT) {
        Ok(config) => Ok(Loaded {
            session,
            config,
            files: files.iter().map(|f| f.display().to_string()).collect(),
        }),
        Err(error) => {
            session.cancel();
            Err(vec![
                json!({ "file": null, "line": null, "column": null, "code": error.code, "message": error.message }),
            ])
        }
    }
}

fn empty_config() -> Value {
    json!({ "actions": [], "keys": [], "modes": [], "removals": [] })
}

impl ConfigOwner {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The live config as the wire reports it, with `applied` for the last load.
    fn report(&self, applied: bool) -> Value {
        let state = self.lock();
        let live = state.live.as_ref().filter(|live| !live.session.is_dead());
        let config = live.map_or_else(empty_config, |live| live.config.clone());
        json!({
            "loaded": live.is_some(),
            "generation": state.generation,
            "dir": scripts_dir().display().to_string(),
            "files": live.map_or_else(Vec::new, |live| live.files.clone()),
            "applied": applied,
            "diagnostics": state.diagnostics,
            "actions": config["actions"],
            "keys": config["keys"],
            "modes": config["modes"],
            "removals": config["removals"],
        })
    }

    /// The live config without loading anything.
    pub(crate) fn status(&self) -> Value {
        self.report(false)
    }

    /// Loads `scripts_dir()` and applies it when every file ran; else keeps
    /// the last good load. Returns the report and whether it applied.
    pub(crate) fn reload(&self, start: Start<'_>, log: LogSink) -> (Value, bool) {
        let _turn = self.turn.lock().unwrap_or_else(PoisonError::into_inner);
        let applied = match load(&scripts_dir(), start, log) {
            Ok(loaded) => {
                let old = {
                    let mut state = self.lock();
                    state.generation += 1;
                    state.diagnostics.clear();
                    state.live.replace(Live {
                        session: Arc::new(loaded.session),
                        config: loaded.config,
                        files: loaded.files,
                    })
                };
                if let Some(old) = old {
                    old.session.cancel();
                }
                true
            }
            Err(diagnostics) => {
                self.lock().diagnostics = diagnostics;
                false
            }
        };
        (self.report(applied), applied)
    }

    /// Loads `path` (the scripts folder or one file) in a session of its
    /// own and reports what it defines, changing nothing.
    pub(crate) fn check(&self, path: &Path, start: Start<'_>, log: LogSink) -> Value {
        match load(path, start, log) {
            Ok(loaded) => {
                loaded.session.cancel();
                json!({ "ok": true, "diagnostics": [], "files": loaded.files, "actions": loaded.config["actions"], "keys": loaded.config["keys"], "modes": loaded.config["modes"], "removals": loaded.config["removals"] })
            }
            Err(diagnostics) => json!({ "ok": false, "diagnostics": diagnostics }),
        }
    }

    /// Runs user action `id` (`user.<name>`) with `args` and `context`
    /// (`{origin, workspace?, pane?, tab?, terminal?}`).
    pub(crate) fn run_action(
        &self,
        id: &str,
        args: Value,
        context: Value,
    ) -> Result<Value, ScriptError> {
        let name = id.strip_prefix("user.").unwrap_or(id);
        let _turn = self.turn.lock().unwrap_or_else(PoisonError::into_inner);
        let session = self
            .lock()
            .live
            .as_ref()
            .filter(|live| !live.session.is_dead())
            .map(|live| live.session.clone())
            .ok_or_else(|| {
                ScriptError::new(NOT_LOADED, "no config scripts are loaded on this cmux")
            })?;
        let result = session.export(
            "action",
            json!({ "name": name, "args": args, "context": context }),
            ACTION_TIMEOUT,
        );
        if session.is_dead() {
            // The action ended the session (time, memory, CPU): say so on status.
            let mut state = self.lock();
            if state.live.as_ref().is_some_and(|live| Arc::ptr_eq(&live.session, &session)) {
                let message = result.as_ref().err().map_or_else(
                    || "the config session ended".to_string(),
                    |error| format!("user.{name} ended the config session: {error}"),
                );
                state.diagnostics = vec![
                    json!({ "file": null, "line": null, "column": null, "code": codes::HOST, "message": message }),
                ];
            }
        }
        result
    }

    /// Ends the live config (daemon shutdown and tests).
    #[allow(dead_code)]
    pub(crate) fn stop(&self) {
        if let Some(live) = self.lock().live.take() {
            live.session.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_load_init_first_then_by_name_and_refuse_typescript() {
        let dir = std::env::temp_dir().join(format!("cmux-config-scripts-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for name in ["b.js", "init.js", "a.mjs", "c.ts", "notes.md"] {
            std::fs::write(dir.join(name), "").unwrap();
        }
        let (files, diagnostics) = files(&dir);
        let names: Vec<_> =
            files.iter().map(|f| f.file_name().unwrap().to_str().unwrap().to_string()).collect();
        assert_eq!(names, ["init.js", "a.mjs", "b.js"]);
        assert_eq!(diagnostics.len(), 1);
        assert!(diagnostics[0]["file"].as_str().unwrap().ends_with("c.ts"));
        assert_eq!(files(&dir.join("missing")), (Vec::new(), Vec::new()));
        assert_eq!(files(&dir.join("b.js")).0.len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn diagnostics_name_the_line_of_the_file_not_the_wrapper() {
        let error = ScriptError::new(codes::ERROR, "SyntaxError: Unexpected token (4:7)");
        let value = diagnostic(Path::new("/c/scripts/a.js"), &error);
        assert_eq!((value["line"].clone(), value["column"].clone()), (json!(3), json!(7)));
        let thrown = ScriptError::new(codes::ERROR, "Error: boom");
        assert_eq!(diagnostic(Path::new("a.js"), &thrown)["line"], Value::Null);
        assert!(wrap("x").starts_with("await (async () => {\nx\n"));
    }

    #[test]
    fn a_failed_start_keeps_nothing_and_reports_it() {
        let owner = ConfigOwner::default();
        let start = |_log: LogSink| Err(ScriptError::new(codes::HOST, "no host"));
        let log: LogSink = Arc::new(|_: &str, _: &str| {});
        let (report, applied) = owner.reload(&start, log.clone());
        assert!(!applied);
        assert_eq!(report["loaded"], false);
        assert_eq!(report["diagnostics"][0]["message"], "no host");
        assert_eq!(owner.run_action("user.x", json!({}), json!({})).unwrap_err().code, NOT_LOADED);
        assert_eq!(owner.check(Path::new("/nonexistent"), &start, log)["ok"], false);
    }
}
