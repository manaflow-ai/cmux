use super::*;

#[test]
fn a_background_or_non_string_command_is_not_read() {
    let fg = json!({"rawInput": {"command": "cargo check"}});
    let bg = json!({"rawInput": {"command": "cargo check", "run_in_background": true}});
    let arr = json!({"rawInput": {"command": ["bash", "-lc", "cargo check"]}});
    assert_eq!(bash_command(&fg).as_deref(), Some("cargo check"));
    assert_eq!(bash_command(&bg), None);
    assert_eq!(bash_command(&arr), None);
}
