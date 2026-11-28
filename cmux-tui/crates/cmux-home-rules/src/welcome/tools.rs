//! The bundled `optchat-chief` tools: which binary the usage tool runs and with what arguments
//! (`ChiefUsageTool`), and the memory export/import arguments (`BundledChiefMemoryTool`). Swift checks
//! which candidate is executable and runs the process.

use super::text::trim;
use crate::ops::{OpError, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

pub const BUNDLED_CHIEF_NAME: &str = "optchat-chief";

fn last_path_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    trimmed.rsplit('/').next().unwrap_or("")
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') { format!("{dir}{name}") } else { format!("{dir}/{name}") }
}

/// `ChiefUsageTool.resolve`'s candidates in order; Swift runs the first that is executable.
pub fn usage_tool_candidates(
    environment: &HashMap<String, String>,
    bin: Option<&str>,
) -> Vec<String> {
    let explicit = environment.get("CMUX_OPTCHAT_CHIEF").filter(|s| !s.is_empty()).cloned();
    // A `CMUX_NEXT_MUX_HOST` that is the TypeScript mux has no `usage`: only an optchat-chief build counts.
    let host = environment
        .get("CMUX_NEXT_MUX_HOST")
        .filter(|s| last_path_component(s) == BUNDLED_CHIEF_NAME)
        .cloned();
    let bundled = bin.map(|b| join(b, BUNDLED_CHIEF_NAME));
    [explicit, host, bundled].into_iter().flatten().collect()
}

/// `ChiefUsageTool.run`'s arguments.
pub fn usage_tool_args(arguments: &[String], mux_home: &str) -> Vec<String> {
    let mut args = arguments.to_vec();
    args.extend(["--mux-home".into(), mux_home.into(), "--chiefs".into(), "--json".into()]);
    args
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MemoryDirection {
    Export,
    Import,
}

/// `BundledChiefMemoryTool.exportText` / `importText` arguments.
pub fn memory_tool_args(
    direction: MemoryDirection,
    mux_home: &str,
    directory: &str,
) -> Vec<String> {
    let list: Vec<&str> = match direction {
        MemoryDirection::Export => {
            vec!["memory", "export", "--text", directory, "--mux-home", mux_home]
        }
        MemoryDirection::Import => vec!["memory", "import", "--mux-home", mux_home, directory],
    };
    list.into_iter().map(str::to_string).collect()
}

/// The memory tool's error text when the process exits non-zero.
pub fn memory_tool_failure(arguments: &[String], stderr: &str) -> String {
    let head: Vec<&str> = arguments.iter().take(2).map(String::as_str).collect();
    format!("{BUNDLED_CHIEF_NAME} {}: {stderr}", head.join(" "))
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct CandidatesRequest {
    environment: HashMap<String, String>,
    bin: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageArgsRequest {
    #[serde(default)]
    arguments: Vec<String>,
    mux_home: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FailureRequest {
    #[serde(default)]
    status: i64,
    #[serde(default)]
    stderr: String,
    #[serde(default)]
    arguments: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MemoryArgsRequest {
    direction: MemoryDirection,
    mux_home: String,
    directory: String,
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "usageToolCandidates" => {
            let req: CandidatesRequest = parse(request)?;
            reply(
                &json!({"candidates": usage_tool_candidates(&req.environment, req.bin.as_deref())}),
            )
        }
        "usageToolArgs" => {
            let req: UsageArgsRequest = parse(request)?;
            reply(&json!({"arguments": usage_tool_args(&req.arguments, &req.mux_home)}))
        }
        "usageToolFailure" => {
            let req: FailureRequest = parse(request)?;
            reply(&json!({"status": req.status, "message": trim(&req.stderr)}))
        }
        "memoryToolPath" => {
            #[derive(Default, Deserialize)]
            #[serde(default)]
            struct Req {
                bin: Option<String>,
            }
            let req: Req = parse(request)?;
            reply(&json!({"path": req.bin.map(|b| join(&b, BUNDLED_CHIEF_NAME))}))
        }
        "memoryToolArgs" => {
            let req: MemoryArgsRequest = parse(request)?;
            reply(
                &json!({"arguments": memory_tool_args(req.direction, &req.mux_home, &req.directory)}),
            )
        }
        "memoryToolFailure" => {
            let req: FailureRequest = parse(request)?;
            reply(&json!({"message": memory_tool_failure(&req.arguments, &req.stderr)}))
        }
        _ => Err(OpError::Unknown),
    }
}
