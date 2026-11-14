use super::super::{CommandPlan, parse as parse_command};

fn params(args: &[&str]) -> serde_json::Value {
    let args = args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    match parse_command(&args, crate::cli::Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) => plan.params,
        _ => panic!("{args:?} is not a protocol request"),
    }
}

/// `screen create` keeps the focus unless `--focus` (bench round 3,
/// T8); `--workspace` places the screen in another workspace.
#[test]
fn w4j_screen_create_sends_focus_only_when_asked_and_takes_a_workspace() {
    let plain = params(&["screen", "create", "--name", "build"]);
    assert!(plain.get("focus").is_none(), "{plain}");
    let quiet = params(&["screen", "create", "--no-focus"]);
    assert!(quiet.get("focus").is_none(), "{quiet}");
    let focused = params(&["screen", "create", "--focus"]);
    assert_eq!(focused["focus"], true);
    let workspace = "ws_00000000000000000000000000000004";
    let placed = params(&["screen", "create", "--workspace", workspace]);
    assert_eq!(placed["workspace"], workspace);
}
