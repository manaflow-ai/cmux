//! The terminal host's task role (macOS). The app starts the daemon and the daemon starts each terminal host, so a
//! host has no task role, and XNU then holds each of its threads at scheduler priority 31 whatever QoS the thread
//! asks for (`cmux_tui_platform::task_role`). The host takes the application role in its real start function,
//! [`enter_terminal_host_process`], before it starts a thread. A process it starts (the shell, a hook helper) gets no
//! role from it.
//!
//! Each test runs the start function in a child process of the test binary and reads the role there, so the test
//! process itself keeps its own role.

const MODE_ENV: &str = "CMUX_TUI_TEST_HOST_TASK_ROLE_CHILD";
const CHILD_TEST: &str = "terminal_host_task_role_child_process";
const MARK: &str = "task-role=";

/// The child side: does nothing in a normal test run.
#[test]
fn terminal_host_task_role_child_process() {
    let Ok(mode) = std::env::var(MODE_ENV) else { return };
    if mode != "plain" {
        crate::terminal_host_runtime::enter_terminal_host_process()
            .expect("the terminal host start function failed");
    }
    if mode == "host-then-child" {
        println!("{MARK}{}", role_of_child("plain"));
    } else {
        println!("{MARK}{}", crate::task_role::current().unwrap_or(-1));
    }
}

/// The task role a child of this process prints after it ran `mode`.
fn role_of_child(mode: &str) -> i32 {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([CHILD_TEST, "--nocapture", "--test-threads", "1"])
        .env(MODE_ENV, mode)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let role = stdout.split(MARK).nth(1).and_then(|rest| {
        let digits =
            rest.chars().take_while(|c| c.is_ascii_digit() || *c == '-').collect::<String>();
        digits.parse::<i32>().ok()
    });
    role.unwrap_or_else(|| {
        panic!(
            "the {mode} child printed no task role ({}): {stdout}\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

#[cfg(target_os = "macos")]
#[test]
fn the_terminal_host_process_takes_the_application_task_role_at_start() {
    assert_eq!(
        role_of_child("host"),
        crate::task_role::APPLICATION,
        "after its start function the terminal host has another task role than TASK_DEFAULT_APPLICATION (7); with \
         no role (0) XNU holds its threads at priority 31 whatever QoS they ask for"
    );
}

#[cfg(target_os = "macos")]
#[test]
fn a_process_the_terminal_host_starts_gets_no_task_role() {
    assert_eq!(
        role_of_child("host-then-child"),
        crate::task_role::UNSPECIFIED,
        "a process the terminal host started (a shell, a hook helper) has a task role"
    );
}
