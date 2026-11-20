//! Classic cmux verbs and the resource commands that replace them.

/// The resource command for a classic cmux verb that agents still run from older
/// skills (tests/tool-evals r3h: GPT 6 Astra tried `rename-workspace`,
/// `workspace-action --action rename` and `list-workspaces` before the MCP tools).
pub(in crate::cli) fn resource_command(scope: &str) -> Option<&'static str> {
    Some(match scope {
        "list-workspaces" => "cmux workspace list",
        "tree" | "current" | "current-workspace" | "current-window" => "cmux identify",
        "new-workspace" => "cmux workspace create --name <name>",
        "rename-workspace" => "cmux workspace current rename <name>",
        "workspace-action" => {
            "cmux workspace current rename <name>` or `cmux workspace current update"
        }
        "select-workspace" => "cmux workspace <workspace> focus",
        "close-workspace" => "cmux workspace <workspace> close",
        "list-surfaces" | "list-pane-surfaces" | "list-tabs" | "tab-list" => "cmux tab list",
        "terminal-list" => "cmux terminal list",
        "new-tab" => "cmux tab create terminal",
        "split-down" | "pane-split-down" => "cmux pane current split --down",
        "new-surface" => "cmux tab create terminal",
        "new-pane" | "new-split" => "cmux pane current split --right",
        "rename-tab" | "rename-surface" | "tab-action" => "cmux tab <tab> rename <name>",
        "close-surface" => "cmux tab <tab> close",
        "send" | "send-text" => "cmux terminal <terminal> write --text <text>",
        "send-key" | "send-keys-to" => "cmux terminal <terminal> keys <key...>",
        "read-screen" | "capture-pane" => "cmux terminal <terminal> screen read",
        _ => return None,
    })
}
