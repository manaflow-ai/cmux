//! `cmux agent-config ...`: Claude Code and Codex customization (hooks
//! today), edited in each agent's own config files by cmux-agent-customize.
//! The Settings page's "Claude Code & Codex" sections run this command.

use serde_json::json;

use super::OutputMode;

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let (first, rest) = words.split_first()?;
    if first != "agent-config" {
        return None;
    }
    let code = match cmux_agent_customize::cli::run(rest) {
        Ok(value) => match global.output {
            OutputMode::Human => {
                print!("{}", cmux_agent_customize::cli::render_human(&value));
                0
            }
            output => super::wire::print_local_success(&value, output),
        },
        Err(error) => super::wire::print_local_error(
            &json!({ "code": "agent_config_failed", "message": format!("{error:#}") }),
            global.output,
            1,
        ),
    };
    Some(code)
}
