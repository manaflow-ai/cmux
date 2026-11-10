//! The terminal owner's task role (macOS). The app starts the daemon, so the daemon has no task role, and XNU
//! then holds each of its threads at scheduler priority 31 whatever QoS the thread asks for
//! (`cmux_tui_platform::task_role`): the input lane of `server/input_qos.rs` asked for user-interactive and got
//! 31. The owner takes the application role in its real start function, [`super::prepare`], before it starts a
//! thread. The test runs it in a child process of the test binary, so the test process keeps its own role.

const MODE_ENV: &str = "CMUX_TUI_TEST_OWNER_TASK_ROLE_CHILD";
const CHILD_TEST: &str = "terminal_owner_task_role_child_process";
const MARK: &str = "task-role=";

/// The child side: does nothing in a normal test run.
#[test]
fn terminal_owner_task_role_child_process() {
    if std::env::var_os(MODE_ENV).is_none() {
        return;
    }
    let args = crate::parse_args_result(Vec::<String>::new()).expect("default arguments");
    super::prepare(&args).expect("the owner start function failed");
    println!("{MARK}{}", cmux_tui_core::task_role::current().unwrap_or(-1));
}

#[test]
fn the_terminal_owner_takes_the_application_task_role_at_start() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([CHILD_TEST, "--nocapture", "--test-threads", "1"])
        .env(MODE_ENV, "owner")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let role = stdout.split(MARK).nth(1).and_then(|rest| {
        let digits =
            rest.chars().take_while(|c| c.is_ascii_digit() || *c == '-').collect::<String>();
        digits.parse::<i32>().ok()
    });
    assert_eq!(
        role,
        Some(cmux_tui_core::task_role::APPLICATION),
        "after its start function the terminal owner has another task role than TASK_DEFAULT_APPLICATION (7); \
         with no role (0) XNU holds its threads at priority 31 whatever QoS they ask for: {stdout}"
    );
}
