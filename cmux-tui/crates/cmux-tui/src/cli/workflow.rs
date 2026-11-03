//! Parser and source resolver for the daemon-owned native workflow command.
//!
//! The actual lifecycle RPC is sent by the CLI dispatcher through the same
//! Server/acpmux path as the MCP `cmux_workflow` tool.  This module only turns
//! argv into a validated invocation and resolves a workflow source under the
//! caller's project `.cmux/workflows` directory.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

const WORKFLOW_SUFFIX: &str = ".workflow.js";

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Invocation {
    Start { name: String, source: String, args: Value, session_id: Option<String> },
    Status { run_id: Option<String> },
    Pause { run_id: String },
    Resume { run_id: String },
    Run { run_id: String, generation: u64 },
}

/// Parse `cmux workflow ...` words.  `workflow __run` is intentionally an
/// internal runner entry point and is accepted only with both fenced fields.
pub(crate) fn parse(words: &[String], cwd: &Path) -> Result<Invocation, String> {
    let Some(action) = words.first().map(String::as_str) else {
        return Err("workflow needs start, status, pause or resume".into());
    };
    match action {
        "start" => parse_start(&words[1..], cwd),
        "status" => parse_id_action(&words[1..], |run_id| Invocation::Status { run_id }),
        "pause" => parse_required_id(&words[1..], "pause", |run_id| Invocation::Pause { run_id }),
        "resume" => {
            parse_required_id(&words[1..], "resume", |run_id| Invocation::Resume { run_id })
        }
        "__run" => parse_run(&words[1..]),
        _ => Err(format!("unknown workflow action {action:?}")),
    }
}

fn parse_start(words: &[String], cwd: &Path) -> Result<Invocation, String> {
    let file = words.first().ok_or("workflow start needs a .workflow.js file")?;
    if file.starts_with('-') {
        return Err("workflow start needs a file before flags".into());
    }
    let mut args = json!({});
    let mut name = None;
    let mut session_id = None;
    let mut index = 1;
    while index < words.len() {
        let flag = words[index].as_str();
        let value = words.get(index + 1).ok_or_else(|| format!("{flag} needs a value"))?;
        match flag {
            "--args-json" => {
                args = serde_json::from_str(value)
                    .map_err(|error| format!("--args-json is invalid JSON: {error}"))?;
            }
            "--name" => name = Some(nonempty(value, "--name")?),
            "--session" | "--session-id" => session_id = Some(nonempty(value, flag)?),
            _ => return Err(format!("unknown workflow start option {flag:?}")),
        }
        index += 2;
    }
    if !args.is_object() {
        return Err("--args-json must be a JSON object".into());
    }
    let source_path = resolve_source(cwd, file)?;
    let source = std::fs::read_to_string(&source_path)
        .map_err(|error| format!("cannot read workflow {}: {error}", source_path.display()))?;
    let default_name = source_path
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_suffix(WORKFLOW_SUFFIX))
        .filter(|name| !name.is_empty())
        .ok_or("workflow file has no name")?;
    Ok(Invocation::Start {
        name: name.unwrap_or_else(|| default_name.to_owned()),
        source,
        args,
        session_id,
    })
}

fn parse_id_action<F>(words: &[String], build: F) -> Result<Invocation, String>
where
    F: FnOnce(Option<String>) -> Invocation,
{
    if words.len() > 1 || words.first().is_some_and(|word| word.starts_with('-')) {
        return Err("workflow status takes at most one run id".into());
    }
    Ok(build(words.first().cloned()))
}

fn parse_required_id<F>(words: &[String], action: &str, build: F) -> Result<Invocation, String>
where
    F: FnOnce(String) -> Invocation,
{
    if words.len() != 1 || words[0].starts_with('-') {
        return Err(format!("workflow {action} needs one run id"));
    }
    Ok(build(nonempty(&words[0], "run id")?))
}

fn parse_run(words: &[String]) -> Result<Invocation, String> {
    if words.len() != 4 || words[0] != "--run-id" || words[2] != "--generation" {
        return Err("workflow __run requires --run-id ID --generation N".into());
    }
    let run_id = nonempty(&words[1], "--run-id")?;
    let generation = words[3]
        .parse::<u64>()
        .map_err(|_| "--generation must be an unsigned integer".to_owned())?;
    Ok(Invocation::Run { run_id, generation })
}

fn resolve_source(cwd: &Path, input: &str) -> Result<PathBuf, String> {
    let root = cwd.join(".cmux").join("workflows").canonicalize().map_err(|error| {
        format!(
            "workflow directory {} is unavailable: {error}",
            cwd.join(".cmux/workflows").display()
        )
    })?;
    let candidate = root.join(input);
    if candidate.extension().and_then(|extension| extension.to_str()) != Some("js")
        || !candidate.to_string_lossy().ends_with(WORKFLOW_SUFFIX)
    {
        return Err(format!("workflow file must end with {WORKFLOW_SUFFIX}"));
    }
    let path = candidate
        .canonicalize()
        .map_err(|error| format!("workflow file is unavailable: {error}"))?;
    if !path.starts_with(&root) {
        return Err("workflow file must stay under .cmux/workflows".into());
    }
    Ok(path)
}

fn nonempty(value: &str, name: &str) -> Result<String, String> {
    (!value.trim().is_empty())
        .then(|| value.to_owned())
        .ok_or_else(|| format!("{name} must be nonempty"))
}

/// Wire shape consumed by `_acpmux/workflow`; kept here so CLI and MCP cannot
/// drift in field spelling.  The hidden runner is handled by `mcp::workflow_run`.
pub(crate) fn request(invocation: &Invocation) -> Value {
    match invocation {
        Invocation::Start { name, source, args, session_id } => json!({
            "action": "start", "name": name, "source": source, "args": args,
            "sessionId": session_id,
        }),
        Invocation::Status { run_id } => json!({"action": "status", "runId": run_id}),
        Invocation::Pause { run_id } => json!({"action": "pause", "runId": run_id}),
        Invocation::Resume { run_id } => json!({"action": "resume", "runId": run_id}),
        Invocation::Run { run_id, generation } => {
            json!({"runId": run_id, "generation": generation})
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fixture() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let workflows = dir.path().join(".cmux/workflows");
        fs::create_dir_all(&workflows).unwrap();
        fs::write(workflows.join("nightly.workflow.js"), "return 42;").unwrap();
        (dir, workflows)
    }

    #[test]
    fn start_resolves_and_pins_source_under_project_directory() {
        let (dir, _) = fixture();
        let invocation =
            parse(&["start".into(), "nightly.workflow.js".into()], dir.path()).unwrap();
        assert_eq!(request(&invocation)["name"], "nightly");
        assert_eq!(request(&invocation)["source"], "return 42;");
    }

    #[test]
    fn start_rejects_path_escape_and_non_workflow_suffix() {
        let (dir, workflows) = fixture();
        fs::write(dir.path().join("outside.js"), "return 1;").unwrap();
        assert!(parse(&["start".into(), "../outside.js".into()], dir.path()).is_err());
        assert!(parse(&["start".into(), "outside.js".into()], dir.path()).is_err());
        assert!(workflows.exists());
    }

    #[test]
    fn lifecycle_and_hidden_runner_require_exact_arguments() {
        assert!(parse(&["pause".into()], Path::new(".")).is_err());
        assert!(parse(&["__run".into(), "--run-id".into(), "wf".into()], Path::new(".")).is_err());
        let run = parse(
            &["__run".into(), "--run-id".into(), "wf".into(), "--generation".into(), "7".into()],
            Path::new("."),
        )
        .unwrap();
        assert_eq!(request(&run)["generation"], 7);
    }
}
