//! cx-0tgl LF: a terminal host's command line names neither its owner's tag
//! (state path) nor the executable it was built in (the app bundle), so
//! cleanup that matches a tag or a bundle path (`pgrep -f <tag>`, `pkill -f
//! "<app>.app"`, a bundle-age reaper) never reaches a host.

use super::*;

/// PIDs whose full command line matches the extended regex `pattern`.
fn pgrep_full(pattern: &str) -> Vec<u32> {
    let output = Command::new("pgrep").arg("-f").arg(pattern).output().unwrap();
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse().ok())
        .collect()
}

fn regex_escape(text: &str) -> String {
    text.chars()
        .flat_map(|ch| {
            let special = "\\.^$|?*+()[]{}".contains(ch);
            special.then_some('\\').into_iter().chain(std::iter::once(ch))
        })
        .collect()
}

#[test]
fn a_terminal_host_command_line_names_no_tag_and_no_bundle() {
    let mut harness = RecoveryHarness::start_unstarted("host-argv-tag-marker");
    let copies = std::env::temp_dir().join(format!("hx-argv-{}", std::process::id()));
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_HOST_EXE_DIR", &copies);
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":"argv"}),
    );
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let tag = harness.dir.file_name().unwrap().to_string_lossy().into_owned();
    let daemon = harness.child.as_ref().unwrap().id();
    // The pattern does match the daemon, whose arguments carry the tag.
    assert!(pgrep_full(&regex_escape(&tag)).contains(&daemon), "pgrep cannot see the daemon");
    assert!(
        !pgrep_full(&regex_escape(&tag)).contains(&record.host_pid),
        "`pgrep -f <tag>` matches the terminal host"
    );
    assert!(
        !pgrep_full(&regex_escape(bin())).contains(&record.host_pid),
        "`pgrep -f <bundle executable>` matches the terminal host"
    );
    let _ = fs::remove_dir_all(&copies);
}
