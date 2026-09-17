use std::collections::HashMap;
use std::path::Path;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use anyhow::Context;
use anyhow::Result;
use anyhow::anyhow;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use serde_json::json;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::output_store::ArtifactSummary;
use crate::output_store::OutputStore;

#[derive(Debug, Clone)]
pub struct ToolRuntime {
    output_store: OutputStore,
}

#[derive(Debug, Clone)]
pub struct SessionToolContext {
    pub cwd: PathBuf,
    pub env: HashMap<String, String>,
}

#[derive(Debug, Serialize)]
struct ExecResult {
    status: String,
    exit_code: Option<i32>,
    timed_out: bool,
    stdout: ArtifactSummary,
    stderr: ArtifactSummary,
}

#[derive(Debug, Deserialize)]
struct ExecArgs {
    argv: Vec<String>,
    cwd: Option<PathBuf>,
    env: Option<HashMap<String, String>>,
    timeout_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct ReadFileArgs {
    path: PathBuf,
}

#[derive(Debug, Deserialize)]
struct ApplyPatchArgs {
    patch: String,
    cwd: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct ReadOutputArgs {
    #[serde(rename = "ref")]
    r#ref: String,
    offset: Option<u64>,
    len: Option<usize>,
    start_line: Option<u64>,
    line_count: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct SearchOutputArgs {
    #[serde(rename = "ref")]
    r#ref: String,
    pattern: String,
    max_matches: Option<usize>,
}

impl ToolRuntime {
    pub fn new(output_store: OutputStore) -> Self {
        Self { output_store }
    }

    pub fn tool_specs() -> Vec<Value> {
        vec![
            json!({
                "type": "function",
                "name": "exec",
                "description": "Run one command directly with structured argv. This does not invoke a shell unless argv[0] is a shell.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "argv": {"type": "array", "items": {"type": "string"}, "minItems": 1},
                        "cwd": {"type": "string"},
                        "env": {"type": "object", "additionalProperties": {"type": "string"}},
                        "timeout_ms": {"type": "integer", "minimum": 1}
                    },
                    "required": ["argv"],
                    "additionalProperties": false
                }
            }),
            json!({
                "type": "function",
                "name": "read_file",
                "description": "Read a file. Small files are returned inline; large files are persisted as blobs and returned by ref.",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                    "additionalProperties": false
                }
            }),
            json!({
                "type": "function",
                "name": "apply_patch",
                "description": "Apply a unified diff to the current workspace using git apply. The patch is passed on stdin, not through a shell.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "patch": {"type": "string"},
                        "cwd": {"type": "string"}
                    },
                    "required": ["patch"],
                    "additionalProperties": false
                }
            }),
            json!({
                "type": "function",
                "name": "read_output",
                "description": "Read exact bytes or exact lines from a persisted tool-output blob ref.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "ref": {"type": "string"},
                        "offset": {"type": "integer", "minimum": 0},
                        "len": {"type": "integer", "minimum": 1},
                        "start_line": {"type": "integer", "minimum": 0},
                        "line_count": {"type": "integer", "minimum": 1}
                    },
                    "required": ["ref"],
                    "additionalProperties": false
                }
            }),
            json!({
                "type": "function",
                "name": "search_output",
                "description": "Search a persisted output blob by substring and return matching line numbers and text.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "ref": {"type": "string"},
                        "pattern": {"type": "string"},
                        "max_matches": {"type": "integer", "minimum": 1}
                    },
                    "required": ["ref", "pattern"],
                    "additionalProperties": false
                }
            }),
        ]
    }

    pub async fn call(&self, context: &SessionToolContext, name: &str, arguments: &str) -> String {
        match self.call_inner(context, name, arguments).await {
            Ok(value) => value.to_string(),
            Err(err) => json!({
                "status": "error",
                "message": err.to_string()
            })
            .to_string(),
        }
    }

    async fn call_inner(
        &self,
        context: &SessionToolContext,
        name: &str,
        arguments: &str,
    ) -> Result<Value> {
        match name {
            "exec" => {
                let args: ExecArgs =
                    serde_json::from_str(arguments).context("parsing exec args")?;
                self.exec(context, args, None).await
            }
            "read_file" => {
                let args: ReadFileArgs =
                    serde_json::from_str(arguments).context("parsing read_file args")?;
                self.read_file(context, args).await
            }
            "apply_patch" => {
                let args: ApplyPatchArgs =
                    serde_json::from_str(arguments).context("parsing apply_patch args")?;
                let exec_args = ExecArgs {
                    argv: vec![
                        "git".into(),
                        "apply".into(),
                        "--whitespace=nowarn".into(),
                        "-".into(),
                    ],
                    cwd: args.cwd,
                    env: None,
                    timeout_ms: Some(30_000),
                };
                self.exec(context, exec_args, Some(args.patch.into_bytes()))
                    .await
            }
            "read_output" => {
                let args: ReadOutputArgs =
                    serde_json::from_str(arguments).context("parsing read_output args")?;
                let text = if let (Some(start), Some(count)) = (args.start_line, args.line_count) {
                    self.output_store.read_lines(&args.r#ref, start, count)?
                } else {
                    self.output_store.read_bytes(
                        &args.r#ref,
                        args.offset.unwrap_or(0),
                        args.len.unwrap_or(64 * 1024),
                    )?
                };
                Ok(json!({"status": "ok", "text": text}))
            }
            "search_output" => {
                let args: SearchOutputArgs =
                    serde_json::from_str(arguments).context("parsing search_output args")?;
                let matches = self.output_store.search(
                    &args.r#ref,
                    &args.pattern,
                    args.max_matches.unwrap_or(100),
                )?;
                Ok(json!({"status": "ok", "matches": matches}))
            }
            other => Err(anyhow!("unknown tool `{other}`")),
        }
    }

    async fn read_file(&self, context: &SessionToolContext, args: ReadFileArgs) -> Result<Value> {
        let path = resolve_path(&context.cwd, &args.path);
        let summary = self.output_store.ingest_file(&path).await?;
        Ok(json!({
            "status": "ok",
            "path": path,
            "content": summary
        }))
    }

    async fn exec(
        &self,
        context: &SessionToolContext,
        args: ExecArgs,
        stdin: Option<Vec<u8>>,
    ) -> Result<Value> {
        validate_argv(&args.argv)?;
        let cwd = args
            .cwd
            .as_ref()
            .map(|cwd| resolve_path(&context.cwd, cwd))
            .unwrap_or_else(|| context.cwd.clone());

        let mut command = Command::new(&args.argv[0]);
        command.args(&args.argv[1..]);
        command.current_dir(&cwd);
        command.stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        });
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());
        command.envs(&context.env);
        if let Some(env) = &args.env {
            command.envs(env);
        }

        let mut child = command
            .spawn()
            .with_context(|| format!("spawning {:?}", args.argv))?;

        if let Some(input) = stdin
            && let Some(mut child_stdin) = child.stdin.take()
        {
            tokio::spawn(async move {
                let _ = child_stdin.write_all(&input).await;
            });
        }

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("child stdout was not piped"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| anyhow!("child stderr was not piped"))?;

        let stdout_store = self.output_store.clone();
        let stderr_store = self.output_store.clone();
        let stdout_task = tokio::spawn(async move { stdout_store.spool_reader(stdout).await });
        let stderr_task = tokio::spawn(async move { stderr_store.spool_reader(stderr).await });

        let timeout = Duration::from_millis(args.timeout_ms.unwrap_or(120_000));
        let wait_result = tokio::time::timeout(timeout, child.wait()).await;
        let (status, timed_out) = match wait_result {
            Ok(status) => (status?, false),
            Err(_) => {
                let _ = child.kill().await;
                (child.wait().await?, true)
            }
        };

        let stdout = stdout_task.await.context("joining stdout spool task")??;
        let stderr = stderr_task.await.context("joining stderr spool task")??;
        let result = ExecResult {
            status: if status.success() && !timed_out {
                "ok".to_string()
            } else {
                "failed".to_string()
            },
            exit_code: status.code(),
            timed_out,
            stdout,
            stderr,
        };
        Ok(serde_json::to_value(result)?)
    }
}

fn resolve_path(cwd: &Path, path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        cwd.join(path)
    }
}

fn validate_argv(argv: &[String]) -> Result<()> {
    if argv.is_empty() {
        return Err(anyhow!("argv must not be empty"));
    }
    for arg in argv {
        if arg.as_bytes().contains(&0) {
            return Err(anyhow!("argv contains NUL byte"));
        }
    }
    Ok(())
}
