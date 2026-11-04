//! Gemini CLI's plan approval, with its plan. In plan mode Gemini writes its plan as a Markdown
//! file in its own plans folder, then calls `exit_plan_mode`. Over ACP that call names the file
//! and nothing else: its `tool_call`, its `session/request_permission` and its end carry the
//! title `Requesting plan approval for: <path>` and no content (gemini-cli 0.66.0 and the
//! 0.67.0 nightly, `packages/core/src/tools/exit-plan-mode.ts` `getDescription`, and
//! `packages/cli/src/acp/acpClient.ts`, which sends a tool's display title and its confirmation's
//! content, and `exit_plan_mode`'s confirmation has none). So acpmux, which runs Gemini on the
//! same machine, reads the file and attaches it the way Grok's and Cursor's plan approvals carry
//! theirs (`xai.rs`, `cursor_ext.rs`): a text block first in the call's `content`, which the
//! transcript draws as Markdown, `rawInput.plan`, and `_meta.acpmux.plan` for the approval card.
//!
//! Only a file in Gemini's own plans folder for the chat's project is read: under
//! `<gemini home>/tmp/<project>/plans/` or `<gemini home>/tmp/<project>/<session>/plans/`, where
//! `<project>`'s `.project_root` marker (gemini-cli `config/projectRegistry.ts`) names the chat's
//! folder. The path is resolved (symlinks too) before it is judged, it must be a Markdown file,
//! and it is stat'ed as a regular file first. Anything else, or a read that fails, leaves the
//! call as Gemini sent it.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The title Gemini gives `exit_plan_mode`, before the plan file's path.
const TITLE: &str = "Requesting plan approval for: ";

/// The marker Gemini writes in each project's temp folder: the project's root path.
const PROJECT_ROOT_FILE: &str = ".project_root";

/// The plan file an `exit_plan_mode` tool call names, from its title.
fn named_plan(tool: &Value) -> Option<&str> {
    let path = tool["title"].as_str()?.strip_prefix(TITLE)?.trim();
    (!path.is_empty()).then_some(path)
}

/// Whether `tool` (a tool call, an update to one, or a request's `toolCall`) is Gemini's
/// `exit_plan_mode` naming a plan file: a title check only, cheap on every update.
pub(super) fn names_plan(tool: &Value) -> bool {
    named_plan(tool).is_some()
}

/// The folders Gemini keeps its state in (gemini-cli `config/storage.ts`
/// `getGlobalRuntimeDir`): `$GEMINI_CLI_HOME/.gemini` or `~/.gemini`, and under macOS's
/// sandbox-exec `~/.cache/.gemini`.
pub(super) fn gemini_homes() -> Vec<PathBuf> {
    let home = std::env::var_os("GEMINI_CLI_HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .or_else(dirs::home_dir);
    let Some(home) = home else { return Vec::new() };
    vec![home.join(".gemini"), home.join(".cache").join(".gemini")]
}

/// `path` resolved the way Gemini's `path.resolve` writes it: absolute, no `.` or `..`.
fn resolved(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// Whether `marker` (a `.project_root` file's text) names `cwd`, as written or resolved.
fn names_project(marker: &str, cwd: &Path) -> bool {
    let owner = resolved(Path::new(marker.trim()));
    if owner.as_os_str().is_empty() {
        return false;
    }
    owner == resolved(cwd)
        || matches!(
            (std::fs::canonicalize(&owner), std::fs::canonicalize(cwd)),
            (Ok(a), Ok(b)) if a == b
        )
}

/// The plan's Markdown, when `path` is a Markdown file in Gemini's plans folder for the project
/// at `cwd` under one of `homes`; None for any other path, or a read that fails.
pub(super) fn read_plan(path: &str, cwd: &Path, homes: &[PathBuf]) -> Option<String> {
    let path = Path::new(path);
    if !path.is_absolute() {
        return None;
    }
    let real = std::fs::canonicalize(path).ok()?;
    if real.extension().and_then(|e| e.to_str()).is_none_or(|e| !e.eq_ignore_ascii_case("md")) {
        return None;
    }
    let inside = homes.iter().any(|home| {
        let Ok(tmp) = std::fs::canonicalize(home.join("tmp")) else { return false };
        let Ok(rest) = real.strip_prefix(&tmp) else { return false };
        let parts: Vec<_> = rest.components().map(|c| c.as_os_str()).collect();
        // <project>/plans/<file...> or <project>/<session>/plans/<file...>.
        let plans = |at: usize| parts.get(at).is_some_and(|part| *part == "plans");
        let planned = (parts.len() >= 3 && plans(1)) || (parts.len() >= 4 && plans(2));
        let Some(project) = parts.first() else { return false };
        planned
            && std::fs::read_to_string(tmp.join(project).join(PROJECT_ROOT_FILE))
                .is_ok_and(|marker| names_project(&marker, cwd))
    });
    if !inside || !std::fs::metadata(&real).ok()?.is_file() {
        return None;
    }
    let text = std::fs::read_to_string(&real).ok()?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// Puts `plan` on an `exit_plan_mode` tool call: a text block before whatever content Gemini
/// sent (its end's "Plan approved: <path>" stays after it), `rawInput.plan` when it has no input,
/// and `_meta.acpmux.plan`.
fn attach(tool: &mut Value, path: &str, plan: &str) {
    let block = json!({"type": "content", "content": {"type": "text", "text": plan}});
    let mut content = vec![block];
    if let Some(sent) = tool["content"].as_array() {
        content.extend(sent.iter().cloned());
    }
    tool.set("content", Value::Array(content));
    if tool.get("rawInput").is_none_or(Value::is_null) {
        tool.set("rawInput", json!({"plan": plan, "plan_path": path}));
    }
    if !tool["_meta"].is_object() {
        tool.set("_meta", json!({}));
    }
    if !tool["_meta"]["acpmux"].is_object() {
        tool["_meta"].set("acpmux", json!({}));
    }
    tool["_meta"]["acpmux"].set("plan", json!({"markdown": plan, "path": path}));
}

/// Attaches the plan to `tool` (a tool call, an update to one, or a permission request's
/// `toolCall`) when it is Gemini's `exit_plan_mode` and its plan file passes `read_plan`.
/// True when it did.
pub(super) fn with_plan(tool: &mut Value, cwd: &Path, homes: &[PathBuf]) -> bool {
    let Some(path) = named_plan(tool).map(str::to_owned) else { return false };
    if tool.pointer("/_meta/acpmux/plan").is_some() {
        return false;
    }
    let Some(plan) = read_plan(&path, cwd, homes) else { return false };
    attach(tool, &path, &plan);
    true
}

/// [`with_plan`] on a `session/update`'s params when the update is a tool call or its update.
pub(super) fn with_plan_update(params: &mut Value, cwd: &Path, homes: &[PathBuf]) -> bool {
    let update = &mut params["update"];
    if !matches!(update["sessionUpdate"].as_str(), Some("tool_call" | "tool_call_update")) {
        return false;
    }
    with_plan(update, cwd, homes)
}

#[cfg(test)]
#[path = "gemini_plan_tests.rs"]
mod tests;
