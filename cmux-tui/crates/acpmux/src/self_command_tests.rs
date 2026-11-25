use super::SelfCommand;
use std::ffi::OsString;
use std::path::PathBuf;

/// The two ways this binary runs: standalone and inside cmux-tui.
pub(crate) fn both() -> [SelfCommand; 2] {
    [
        SelfCommand::new(PathBuf::from("/opt/cmux/bin/acpmux"), Vec::new()),
        SelfCommand::new(PathBuf::from("/opt/cmux/bin/cmux-tui"), vec![OsString::from("acp")]),
    ]
}

#[test]
fn subcommands_follow_the_prefix() {
    let [standalone, tui] = both();
    assert_eq!(standalone.args(&["daemon", "run"]), ["daemon", "run"]);
    assert_eq!(tui.args(&["daemon", "run"]), ["acp", "daemon", "run"]);
    assert_eq!(tui.args_lossy::<&str>(&[]), ["acp"]);
    let command = tui.command(&["router", "serve"]);
    assert_eq!(command.get_program(), "/opt/cmux/bin/cmux-tui");
    let args: Vec<_> = command.get_args().collect();
    assert_eq!(args, ["acp", "router", "serve"]);
    let command = tui.tokio_command(&["subsession-mcp"]);
    let args: Vec<_> = command.as_std().get_args().collect();
    assert_eq!(args, ["acp", "subsession-mcp"]);
}

/// This process's own binary runs from the open inode on Linux, with
/// argv0 the path; another binary runs as given.
#[test]
fn its_own_binary_runs_from_the_open_inode_on_linux() {
    let this = SelfCommand::current().expect("this binary");
    let exe = std::env::current_exe().expect("current exe");
    assert_eq!(this.exe, exe);
    let command = this.command(&["daemon", "run"]);
    if cfg!(target_os = "linux") {
        assert_eq!(command.get_program(), "/proc/self/exe");
    } else {
        assert_eq!(command.get_program(), exe);
    }
    let [standalone, _] = both();
    assert_eq!(standalone.program(), PathBuf::from("/opt/cmux/bin/acpmux"));
}

#[test]
fn a_replaced_file_reads_as_its_path() {
    let path = "/home/cmux/.cmux/bin/cmux-tui";
    assert_eq!(super::undeleted(format!("{path} (deleted)").into()), PathBuf::from(path));
    assert_eq!(super::undeleted(path.into()), PathBuf::from(path));
}
