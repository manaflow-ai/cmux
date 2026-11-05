//! Cloud repository actions shared by the CLI, app and agent MCP tools.
//! Local Mac remotes are synchronized as names, never paths or credentials.

mod engine;
pub mod local;
mod runtime;
mod store;
#[cfg(test)]
mod tests;

pub(crate) use engine::{Backend, Catalog, Failure, Repo, add, list};
pub(crate) use runtime::handle;

pub const OPERATIONS: &[&str] = &[
    "cloud.repo.list",
    "cloud.repo.add",
    "cloud.repo.attached",
    "cloud.repo.wait_github",
    "cloud.repo.local",
    "cloud.repo.remember",
    "cloud.repo.sync",
];

pub fn frame_command(line: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    if value.get("protocol").is_some() {
        return None;
    }
    let cmd = value.get("cmd")?.as_str()?;
    OPERATIONS.contains(&cmd).then(|| cmd.to_owned())
}
