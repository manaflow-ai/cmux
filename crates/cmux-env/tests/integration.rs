use assert_cmd::prelude::*;
use predicates::prelude::*;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::TempDir;
use expectrl::{spawn, ControlCode};

fn start_envd_with_runtime(tmp: &TempDir) -> std::process::Child {
    let mut cmd = Command::cargo_bin("envd").expect("binary envd");
    cmd.env("XDG_RUNTIME_DIR", tmp.path());
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());
    let mut child = cmd.spawn().expect("start envd");
    // Wait for socket to show up
    let sock = tmp.path().join("cmux-envd/envd.sock");
    let start = Instant::now();
    while !sock.exists() {
        if start.elapsed() > Duration::from_secs(3) {
            let _ = child.kill();
            panic!("envd socket did not appear: {}", sock.display());
        }
        thread::sleep(Duration::from_millis(50));
    }
    child
}

fn run_envctl(tmp: &TempDir, args: &[&str]) -> assert_cmd::assert::Assert {
    let mut cmd = Command::cargo_bin("envctl").unwrap();
    cmd.env("XDG_RUNTIME_DIR", tmp.path());
    for a in args { cmd.arg(a); }
    cmd.assert()
}

#[test]
fn ping_and_status() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    run_envctl(&tmp, &["ping"]).success().stdout(predicate::str::contains("pong"));
    run_envctl(&tmp, &["status"]).success().stdout(predicate::str::contains("generation:"));

    let _ = child.kill();
    let _ = child.wait();
    let _ = child.wait();
    let _ = child.wait();
}

#[test]
fn set_and_export_bash() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    run_envctl(&tmp, &["set", "FOO=bar"]).success();
    // export since 0 should contain FOO
    run_envctl(&tmp, &["export", "bash", "--since", "0"]).success()
        .stdout(predicate::str::contains("export FOO='bar'"))
        .stdout(predicate::str::contains("ENVCTL_GEN"));

    // Nothing changed since current gen -> only ENVCTL_GEN should appear, no FOO
    // We don't know current gen, so call export again since 0 should still include FOO
    run_envctl(&tmp, &["unset", "FOO"]).success();
    run_envctl(&tmp, &["export", "bash", "--since", "0"]).success()
        .stdout(predicate::str::contains("unset -v FOO"));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn dir_scoped_overlay() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    // Create a directory structure
    let base = tmp.path().join("proj");
    let nested = base.join("sub");
    std::fs::create_dir_all(&nested).unwrap();

    // Set global and dir-specific
    run_envctl(&tmp, &["set", "VAR=global"]).success();
    run_envctl(&tmp, &["set", "VAR=local", "--dir", base.to_str().unwrap()]).success();

    // Export for nested dir should pick local
    run_envctl(&tmp, &["export", "bash", "--since", "0", "--pwd", nested.to_str().unwrap()])
        .success().stdout(predicate::str::contains("export VAR='local'"));

    // Export for unrelated dir should pick global
    let other = tmp.path().join("other");
    std::fs::create_dir_all(&other).unwrap();
    run_envctl(&tmp, &["export", "bash", "--since", "0", "--pwd", other.to_str().unwrap()])
        .success().stdout(predicate::str::contains("export VAR='global'"));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn export_then_eval_in_bash_updates_env() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    // Set a var and then eval the export in a bash subshell; verify env reflects it
    run_envctl(&tmp, &["set", "FOO=bar"]).success();

    let script = Command::cargo_bin("envctl").unwrap()
        .env("XDG_RUNTIME_DIR", tmp.path())
        .arg("export").arg("bash").arg("--since").arg("0")
        .output().unwrap();
    assert!(script.status.success());
    let export = String::from_utf8_lossy(&script.stdout).to_string();

    // Run a bash shell to eval the script and echo $FOO afterwards
    let mut bash = Command::new("bash");
    bash.env("XDG_RUNTIME_DIR", tmp.path());
    bash.arg("-lc");
    let cmdline = format!("{}\necho $FOO", export);
    bash.arg(cmdline);
    let out = bash.output().unwrap();
    assert!(out.status.success());
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(s.lines().last().unwrap_or("") == "bar");

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn minimal_diff_with_generation() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    run_envctl(&tmp, &["set", "X=1"]).success();
    let first = Command::cargo_bin("envctl").unwrap()
        .env("XDG_RUNTIME_DIR", tmp.path())
        .arg("export").arg("bash").arg("--since").arg("0")
        .output().unwrap();
    assert!(first.status.success());
    let out = String::from_utf8_lossy(&first.stdout);
    // extract new generation from last line
    let gen_line = out.lines().last().unwrap_or("");
    assert!(gen_line.contains("ENVCTL_GEN"));

    // parse gen
    let gen: u64 = gen_line.split('=').next_back().unwrap().trim().parse().unwrap();

    // No change; export again since current gen should not include X=1 again
    let second = Command::cargo_bin("envctl").unwrap()
        .env("XDG_RUNTIME_DIR", tmp.path())
        .env("ENVCTL_GEN", gen.to_string())
        .arg("export").arg("bash")
        .output().unwrap();
    assert!(second.status.success());
    let out2 = String::from_utf8_lossy(&second.stdout);
    assert!(!out2.contains("export X='1'"), "should not re-export unchanged var");
    assert!(out2.contains("ENVCTL_GEN"));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn interactive_shell_next_command_reflects_set() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    // Prepare a bash rcfile with the new preexec hook
    let rc = tmp.path().join("bashrc");
    std::fs::write(&rc, format!(
        r#"export XDG_RUNTIME_DIR="{}"
export ENVCTL_GEN=0
export PATH="/app/target/debug:$PATH"
{}
"#,
        tmp.path().display(),
        hook_text_bash()
    )).unwrap();

    // Spawn bash on a pty
    let mut p = spawn(format!("bash --noprofile --rcfile {} -i", rc.display())).unwrap();

    // Wait for first prompt (we don't know exact PS1; just send an Enter and expect another prompt)
    p.send(ControlCode::CarriageReturn).unwrap();

    // From outside (this test), set BAR=42 via envctl
    run_envctl(&tmp, &["set", "BAR=42"]).success();

    // Now in bash, the next command should see BAR because preexec runs before command
    p.send_line(r#"printf "%s\n" "$BAR""#).unwrap();
    // Expect '42'
    p.expect("42").unwrap();

    let _ = child.kill();
    let _ = child.wait();
}

fn hook_text_bash() -> String {
    // Replicate the bash hook emitted by envctl hook bash
    r#"__envctl_apply() {
  local out
  out="$(envctl export bash --since "${ENVCTL_GEN:-0}" --pwd "$PWD")" || return
  eval "$out"
}
__envctl_debug_trap() {
  trap - DEBUG
  __envctl_apply
  trap '__envctl_debug_trap' DEBUG
}
trap '__envctl_debug_trap' DEBUG
__envctl_apply
"#.to_string()
}

#[test]
fn load_from_stdin() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    let input = b"FOO=bar\n# comment\nBAZ=qux\n";
    let mut cmd = Command::cargo_bin("envctl").unwrap();
    cmd.env("XDG_RUNTIME_DIR", tmp.path());
    cmd.arg("load").arg("-");
    cmd.stdin(Stdio::piped());
    let mut ch = cmd.spawn().unwrap();
    use std::io::Write;
    ch.stdin.as_mut().unwrap().write_all(input).unwrap();
    let out = ch.wait_with_output().unwrap();
    assert!(out.status.success());

    // List should include FOO and BAZ
    run_envctl(&tmp, &["list"]).success()
        .stdout(predicate::str::contains("FOO=bar").and(predicate::str::contains("BAZ=qux")));

    let _ = child.kill();
    let _ = child.wait();
}

