use serde_json::json;

use super::{AppCommand, parse_batch};

fn parse(args: &[&str], stdin: &str) -> Result<AppCommand, String> {
    let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
    parse_batch(&args, &mut stdin.as_bytes(), "script").map_err(|error| error.to_string())
}

#[test]
fn json_lines_become_one_batch_request_in_order() {
    let command = parse(
            &[],
            "{\"action\":\"newColumn\",\"target\":\"pane_1\"}\n\n{\"action\":\"renameTab\",\"args\":{\"name\":\"a\"},\"origin\":\"mcp\"}\n",
        )
        .unwrap();
    let AppCommand::Call { method, params, .. } = command else { panic!("not a call") };
    assert_eq!(method, "action.batch");
    assert_eq!(
        params,
        json!({
            "ops": [
                {"action": "newColumn", "target": "pane_1", "origin": "script"},
                {"action": "renameTab", "args": {"name": "a"}, "origin": "mcp"},
            ],
            "wait": true,
        })
    );
}

#[test]
fn a_json_array_and_the_flags_are_read() {
    let command = parse(&["--no-wait", "--no-atomic"], "[{\"action\":\"newRow\"}]").unwrap();
    let AppCommand::Call { params, .. } = command else { panic!("not a call") };
    assert_eq!(
        params,
        json!({"ops": [{"action": "newRow", "origin": "script"}], "wait": false, "atomic": false})
    );
}

#[test]
fn empty_stdin_a_bad_line_or_a_non_object_runs_nothing() {
    assert!(parse(&[], " \n").is_err());
    assert!(parse(&[], "{\"action\":\"newRow\"}\nnot json\n").unwrap_err().contains('2'));
    assert!(parse(&[], "[1]").is_err());
    assert!(parse(&["--target"], "{\"action\":\"newRow\"}").is_err());
}
