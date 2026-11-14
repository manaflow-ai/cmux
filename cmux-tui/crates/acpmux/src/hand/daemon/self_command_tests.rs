#[test]
fn the_keyed_start_runs_under_the_daemon_prefix() {
    let [standalone, tui] = crate::self_command::test_commands();
    let args = |c: &tokio::process::Command| -> Vec<String> {
        c.as_std().get_args().map(|a| a.to_string_lossy().into_owned()).collect()
    };
    let start = ["daemon", "start", "--person-key-fd", "0"];
    assert_eq!(args(&super::keyed_start_command(&standalone)), start);
    let command = super::keyed_start_command(&tui);
    assert_eq!(command.as_std().get_program(), tui.exe.as_os_str());
    assert_eq!(args(&command)[0], "acp");
    assert_eq!(args(&command)[1..], start);
}
