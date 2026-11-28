use super::*;
use std::path::Path;

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|a| (*a).to_owned()).collect()
}

#[test]
fn a_wrapped_launch_yields_its_profile_and_parameters_only() {
    let args = s(&["-p", "(version 1)", "-D", "CWD=/w", "-D", "HOME=/h", "/bin/claude", "-D", "x"]);
    let got = launch_prefix(Path::new(crate::local_sandbox::SANDBOX_EXEC), &args);
    assert_eq!(got, Some(s(&["-p", "(version 1)", "-D", "CWD=/w", "-D", "HOME=/h"])));
}

#[test]
fn an_unwrapped_or_malformed_launch_has_no_boundary() {
    assert_eq!(launch_prefix(Path::new("/bin/claude"), &s(&["-p", "x", "claude"])), None);
    let exec = Path::new(crate::local_sandbox::SANDBOX_EXEC);
    assert_eq!(launch_prefix(exec, &s(&["-f", "x", "claude"])), None);
    // No program after the parameters: not a launch this module made.
    assert_eq!(launch_prefix(exec, &s(&["-p", "x", "-D", "A=b"])), None);
}

#[test]
fn a_bound_task_runs_its_shell_inside_sandbox_exec() {
    let prefix = s(&["-p", "P", "-D", "CWD=/w"]);
    let (program, args) = wrap_shell(Some(&prefix), "/bin/bash", "make test");
    assert_eq!(program, crate::local_sandbox::SANDBOX_EXEC);
    assert_eq!(args, s(&["-p", "P", "-D", "CWD=/w", "/bin/bash", "-c", "make test"]));
    let (program, args) = wrap_shell(None, "/bin/bash", "make test");
    assert_eq!((program.as_str(), args), ("/bin/bash", s(&["-c", "make test"])));
}

#[test]
fn command_prefix_reads_a_built_command() {
    let mut cmd = std::process::Command::new(crate::local_sandbox::SANDBOX_EXEC);
    cmd.args(["-p", "P", "-D", "CWD=/w", "/bin/claude", "--print"]);
    assert_eq!(command_prefix(&cmd), Some(s(&["-p", "P", "-D", "CWD=/w"])));
}
