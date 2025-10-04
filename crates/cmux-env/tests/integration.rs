use assert_cmd::{cargo::cargo_bin, prelude::*};
use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine};
use expectrl::{spawn, ControlCode};
use predicates::prelude::*;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::TempDir;

fn kill_envd_by_pid(tmp: &TempDir) {
    let pid_path = tmp.path().join("cmux-envd/envd.pid");
    let contents = match std::fs::read_to_string(&pid_path) {
        Ok(s) => s,
        Err(_) => return,
    };
    let pid = match contents.trim().parse::<libc::pid_t>() {
        Ok(pid) => pid,
        Err(_) => return,
    };
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }
    thread::sleep(Duration::from_millis(100));
    unsafe {
        libc::kill(pid, libc::SIGKILL);
    }
}

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
    for a in args {
        cmd.arg(a);
    }
    cmd.assert()
}

#[test]
fn ping_and_status() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    run_envctl(&tmp, &["ping"])
        .success()
        .stdout(predicate::str::contains("pong"));
    run_envctl(&tmp, &["status"])
        .success()
        .stdout(predicate::str::contains("generation:"));

    let _ = child.kill();
    let _ = child.wait();
    let _ = child.wait();
    let _ = child.wait();
}

#[test]
fn lazy_start_on_first_set() {
    let tmp = TempDir::new().unwrap();

    let sock = tmp.path().join("cmux-envd/envd.sock");
    assert!(!sock.exists());

    run_envctl(&tmp, &["set", "LAZY=1"]).success();

    assert!(sock.exists());

    run_envctl(&tmp, &["get", "LAZY"])
        .success()
        .stdout(predicate::str::contains("1"));

    run_envctl(&tmp, &["status"])
        .success()
        .stdout(predicate::str::contains("generation:"));

    kill_envd_by_pid(&tmp);
}

#[test]
fn set_and_export_bash() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    run_envctl(&tmp, &["set", "FOO=bar"]).success();
    // export since 0 should contain FOO
    run_envctl(&tmp, &["export", "bash", "--since", "0"])
        .success()
        .stdout(predicate::str::contains("export FOO='bar'"))
        .stdout(predicate::str::contains("ENVCTL_GEN"));

    // Nothing changed since current gen -> only ENVCTL_GEN should appear, no FOO
    // We don't know current gen, so call export again since 0 should still include FOO
    run_envctl(&tmp, &["unset", "FOO"]).success();
    run_envctl(&tmp, &["export", "bash", "--since", "0"])
        .success()
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
    run_envctl(
        &tmp,
        &[
            "export",
            "bash",
            "--since",
            "0",
            "--pwd",
            nested.to_str().unwrap(),
        ],
    )
    .success()
    .stdout(predicate::str::contains("export VAR='local'"));

    // Export for unrelated dir should pick global
    let other = tmp.path().join("other");
    std::fs::create_dir_all(&other).unwrap();
    run_envctl(
        &tmp,
        &[
            "export",
            "bash",
            "--since",
            "0",
            "--pwd",
            other.to_str().unwrap(),
        ],
    )
    .success()
    .stdout(predicate::str::contains("export VAR='global'"));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn get_and_list_default_to_client_pwd() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    let base = tmp.path().join("proj");
    let nested = base.join("sub");
    std::fs::create_dir_all(&nested).unwrap();

    run_envctl(&tmp, &["set", "VAR=global"]).success();
    run_envctl(&tmp, &["set", "VAR=local", "--dir", base.to_str().unwrap()]).success();
    run_envctl(
        &tmp,
        &["set", "ONLY_OVERLAY=1", "--dir", base.to_str().unwrap()],
    )
    .success();

    let mut get_cmd = Command::cargo_bin("envctl").unwrap();
    get_cmd.env("XDG_RUNTIME_DIR", tmp.path());
    get_cmd.current_dir(&nested);
    get_cmd.arg("get").arg("VAR");
    get_cmd
        .assert()
        .success()
        .stdout(predicate::str::contains("local"));

    let mut list_cmd = Command::cargo_bin("envctl").unwrap();
    list_cmd.env("XDG_RUNTIME_DIR", tmp.path());
    list_cmd.current_dir(&nested);
    list_cmd.arg("list");
    list_cmd
        .assert()
        .success()
        .stdout(predicate::str::contains("ONLY_OVERLAY"));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn export_then_eval_in_bash_updates_env() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    // Set a var and then eval the export in a bash subshell; verify env reflects it
    run_envctl(&tmp, &["set", "FOO=bar"]).success();

    let script = Command::cargo_bin("envctl")
        .unwrap()
        .env("XDG_RUNTIME_DIR", tmp.path())
        .arg("export")
        .arg("bash")
        .arg("--since")
        .arg("0")
        .output()
        .unwrap();
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
fn multi_line_value_round_trip_via_export() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    let multi_line_val = "hellowrold\nthisissecondline\nyesyesyes";
    let set_arg = format!("MULTI_LINE_THING={}", multi_line_val);
    let set_args = ["set", set_arg.as_str()];
    run_envctl(&tmp, &set_args).success();

    let output = Command::cargo_bin("envctl")
        .unwrap()
        .env("XDG_RUNTIME_DIR", tmp.path())
        .arg("get")
        .arg("MULTI_LINE_THING")
        .output()
        .unwrap();
    assert!(output.status.success());
    let retrieved = String::from_utf8_lossy(&output.stdout).to_string();
    assert_eq!(retrieved, format!("{}\n", multi_line_val));

    let script = Command::cargo_bin("envctl")
        .unwrap()
        .env("XDG_RUNTIME_DIR", tmp.path())
        .arg("export")
        .arg("bash")
        .arg("--since")
        .arg("0")
        .output()
        .unwrap();
    assert!(script.status.success());
    let export = String::from_utf8_lossy(&script.stdout).to_string();
    assert!(export.contains("export MULTI_LINE_THING='hellowrold\nthisissecondline\nyesyesyes'"));

    let mut bash = Command::new("bash");
    bash.env("XDG_RUNTIME_DIR", tmp.path());
    bash.arg("-lc");
    let verify = format!(
        "{}\nprintf '__START__%s__END__' \"$MULTI_LINE_THING\"",
        export
    );
    bash.arg(verify);
    let out = bash.output().unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let expected = format!("__START__{}__END__", multi_line_val);
    assert_eq!(stdout, expected);

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn minimal_diff_with_generation() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    run_envctl(&tmp, &["set", "X=1"]).success();
    let first = Command::cargo_bin("envctl")
        .unwrap()
        .env("XDG_RUNTIME_DIR", tmp.path())
        .arg("export")
        .arg("bash")
        .arg("--since")
        .arg("0")
        .output()
        .unwrap();
    assert!(first.status.success());
    let out = String::from_utf8_lossy(&first.stdout);
    // extract new generation from last line
    let gen_line = out.lines().last().unwrap_or("");
    assert!(gen_line.contains("ENVCTL_GEN"));

    // parse gen
    let gen: u64 = gen_line
        .split('=')
        .next_back()
        .unwrap()
        .trim()
        .parse()
        .unwrap();

    // No change; export again since current gen should not include X=1 again
    let second = Command::cargo_bin("envctl")
        .unwrap()
        .env("XDG_RUNTIME_DIR", tmp.path())
        .env("ENVCTL_GEN", gen.to_string())
        .arg("export")
        .arg("bash")
        .output()
        .unwrap();
    assert!(second.status.success());
    let out2 = String::from_utf8_lossy(&second.stdout);
    assert!(
        !out2.contains("export X='1'"),
        "should not re-export unchanged var"
    );
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
    let envctl_path = cargo_bin("envctl");
    let envctl_dir = envctl_path.parent().expect("envctl parent dir");
    std::fs::write(
        &rc,
        format!(
            r#"export XDG_RUNTIME_DIR="{runtime}"
export ENVCTL_GEN=0
export PATH="{env_dir}:$PATH"
{hook}
"#,
            runtime = tmp.path().display(),
            env_dir = envctl_dir.display(),
            hook = hook_text_bash()
        ),
    )
    .unwrap();

    // Spawn bash on a pty
    let mut p = spawn(format!("bash --noprofile --rcfile {} -i", rc.display())).unwrap();

    // Wait for first prompt (we don't know exact PS1; just send an Enter and expect another prompt)
    p.send(ControlCode::CarriageReturn).unwrap();

    // From outside (this test), set BAR=42 via envctl
    run_envctl(&tmp, &["set", "BAR=42"]).success();

    // Now in bash, the next command should see BAR because preexec runs before command
    p.send_line("printf '%s\\n' \"$BAR\"").unwrap();
    // Expect '42'
    p.expect("42").unwrap();

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn interactive_shell_chains_existing_debug_trap() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    run_envctl(&tmp, &["set", "CHAINED=ok"]).success();

    let rc = tmp.path().join("bashrc");
    let log_path = tmp.path().join("debug.log");
    let envctl_path = cargo_bin("envctl");
    let envctl_dir = envctl_path.parent().expect("envctl parent dir");
    std::fs::write(
        &rc,
        format!(
            r#"export XDG_RUNTIME_DIR="{runtime}"
export ENVCTL_GEN=0
export PATH="{env_dir}:$PATH"
__existing_debug_log="{log}"
__existing_debug_trap() {{
  printf '%s:%s\n' "$BASH_COMMAND" "$1" >> "$__existing_debug_log"
}}
trap '__existing_debug_trap "$_"' DEBUG
{hook}
"#,
            runtime = tmp.path().display(),
            env_dir = envctl_dir.display(),
            log = log_path.display(),
            hook = hook_text_bash()
        ),
    )
    .unwrap();

    let mut p = spawn(format!("bash --noprofile --rcfile {} -i", rc.display())).unwrap();
    p.send(ControlCode::CarriageReturn).unwrap();

    p.send_line("printf '__VAL__:%s\\n' \"$CHAINED\"").unwrap();
    p.expect("__VAL__:ok").unwrap();

    let log_contents = std::fs::read_to_string(&log_path).unwrap();
    assert!(
        log_contents.contains("printf '__VAL__:%s\\n' \"$CHAINED\":"),
        "unexpected log contents:\n{}",
        log_contents
    );

    p.send_line("exit").unwrap();

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn install_hook_installs_bash_block() {
    let tmp = TempDir::new().unwrap();
    let home = tmp.path().join("home");
    fs::create_dir_all(&home).unwrap();
    let rc = home.join(".bashrc");
    fs::write(&rc, "export FOO=1\n").unwrap();

    let hook_output = Command::cargo_bin("envctl")
        .unwrap()
        .arg("hook")
        .arg("bash")
        .output()
        .unwrap();
    assert!(hook_output.status.success());
    let hook_text = String::from_utf8_lossy(&hook_output.stdout).to_string();

    let mut cmd = Command::cargo_bin("envctl").unwrap();
    cmd.env("HOME", &home);
    cmd.env("XDG_RUNTIME_DIR", tmp.path());
    cmd.arg("install-hook").arg("bash");
    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Installed envctl hook for bash"));

    let contents = fs::read_to_string(&rc).unwrap();
    assert!(contents.starts_with("export FOO=1"));
    assert_eq!(contents.matches("# >>> envctl hook >>>").count(), 1);
    assert_eq!(contents.matches("# <<< envctl hook <<<").count(), 1);
    assert!(contents.contains(hook_text.trim()));

    let mut second = Command::cargo_bin("envctl").unwrap();
    second.env("HOME", &home);
    second.env("XDG_RUNTIME_DIR", tmp.path());
    second.arg("install-hook").arg("bash");
    second.assert().success();

    let contents2 = fs::read_to_string(&rc).unwrap();
    assert_eq!(contents2.matches("# >>> envctl hook >>>").count(), 1);
    assert!(contents2.contains("export FOO=1"));
}

#[test]
fn install_hook_multiple_shells_share_state() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    let home = tmp.path().join("home");
    fs::create_dir_all(&home).unwrap();
    let rc = home.join(".bashrc");
    let envctl_path = cargo_bin("envctl");
    let envctl_dir = envctl_path.parent().expect("envctl dir");
    fs::write(
        &rc,
        format!(
            "export XDG_RUNTIME_DIR=\"{}\"\nexport ENVCTL_GEN=0\nexport PATH=\"{}:$PATH\"\n",
            tmp.path().display(),
            envctl_dir.display()
        ),
    )
    .unwrap();

    let status = Command::cargo_bin("envctl")
        .unwrap()
        .env("HOME", &home)
        .env("XDG_RUNTIME_DIR", tmp.path())
        .arg("install-hook")
        .arg("bash")
        .arg("--rcfile")
        .arg(&rc)
        .status()
        .unwrap();
    assert!(status.success());

    let launcher = tmp.path().join("launch.sh");
    let script = format!(
        "#!/usr/bin/env bash\nexport HOME={home}\nexport XDG_RUNTIME_DIR={runtime}\nexport PATH={envctl_dir}:\"$PATH\"\nexec bash --noprofile --rcfile {rc} -i\n",
        home = shell_escape(&home.to_string_lossy()),
        runtime = shell_escape(&tmp.path().to_string_lossy()),
        envctl_dir = shell_escape(&envctl_dir.to_string_lossy()),
        rc = shell_escape(&rc.to_string_lossy())
    );
    fs::write(&launcher, script).unwrap();
    let mut perms = fs::metadata(&launcher).unwrap().permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&launcher, perms).unwrap();
    let launcher_cmd = launcher.to_string_lossy().to_string();

    let mut shell1 = spawn(launcher_cmd.as_str()).unwrap();
    shell1.send(ControlCode::CarriageReturn).unwrap();
    shell1.send_line("printf '__READY__\\n'").unwrap();
    shell1.expect("__READY__").unwrap();

    let mut shell2 = spawn(launcher_cmd.as_str()).unwrap();
    shell2.send(ControlCode::CarriageReturn).unwrap();
    shell2.send_line("printf '__READY__\\n'").unwrap();
    shell2.expect("__READY__").unwrap();

    shell2
        .send_line("printf '__VAL__:%s\\n' \"${SHARED:-missing}\"")
        .unwrap();
    shell2.expect("__VAL__:missing").unwrap();

    shell1
        .send_line("envctl set SHARED=from_shell1; printf '__SET__\\n'")
        .unwrap();
    shell1.expect("__SET__").unwrap();

    shell1
        .send_line("printf '__SELF__:%s\\n' \"${SHARED:-missing}\"")
        .unwrap();
    shell1.expect("__SELF__:from_shell1").unwrap();

    shell2
        .send_line("printf '__VAL__:%s\\n' \"${SHARED:-missing}\"")
        .unwrap();
    shell2.expect("__VAL__:from_shell1").unwrap();

    shell2
        .send_line("envctl set SHARED=from_shell2; printf '__SET2__\\n'")
        .unwrap();
    shell2.expect("__SET2__").unwrap();

    shell1
        .send_line("printf '__SELF2__:%s\\n' \"${SHARED:-missing}\"")
        .unwrap();
    shell1.expect("__SELF2__:from_shell2").unwrap();

    shell1.send_line("exit").unwrap();
    shell2.send_line("exit").unwrap();

    drop(shell1);
    drop(shell2);

    let _ = child.kill();
    let _ = child.wait();
}

fn shell_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

fn hook_text_bash() -> String {
    // Replicate the bash hook emitted by envctl hook bash
    r#"__envctl_apply() {
  local out
  out="$(envctl export bash --since "${ENVCTL_GEN:-0}" --pwd "$PWD")" || return
  eval "$out"
}
__envctl_capture_debug_trap() {
  builtin local -a __envctl_terms
  builtin eval "__envctl_terms=( $(trap -p DEBUG) )" 2>/dev/null || return
  if (( ${#__envctl_terms[@]} >= 3 )); then
    builtin printf '%s' "${__envctl_terms[2]}"
  fi
}
__envctl_debug_trap() {
  local __envctl_status=$?
  local __envctl_trap_arg="$1"
  if (( ${__envctl_in_debug_trap:-0} )); then
    return $__envctl_status
  fi
  __envctl_in_debug_trap=1
  local __envctl_saved_bash_command=$BASH_COMMAND
  local __envctl_saved_arg="$__envctl_trap_arg"
  __envctl_apply
  if [[ -n "${__envctl_prev_debug_trap:-}" ]]; then
    BASH_COMMAND=$__envctl_saved_bash_command
    : "$__envctl_saved_arg"
    builtin eval "${__envctl_prev_debug_trap}"
  fi
  __envctl_in_debug_trap=0
  return $__envctl_status
}
if [[ -z "${__envctl_debug_trap_installed:-}" ]]; then
  __envctl_prev_debug_trap="$(__envctl_capture_debug_trap)"
  if [[ "${__envctl_prev_debug_trap}" == '__envctl_debug_trap'* ]]; then
    __envctl_prev_debug_trap=''
  fi
  __envctl_debug_trap_installed=1
fi
trap '__envctl_debug_trap "$_"' DEBUG
__envctl_apply
"#
    .to_string()
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
    run_envctl(&tmp, &["list"])
        .success()
        .stdout(predicate::str::contains("FOO=bar").and(predicate::str::contains("BAZ=qux")));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn load_from_base64_literal() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    let content = "FOO=bar\nBAZ=qux\n";
    let encoded = BASE64_STANDARD.encode(content);

    run_envctl(&tmp, &["load", "--base64", &encoded]).success();

    run_envctl(&tmp, &["list"])
        .success()
        .stdout(predicate::str::contains("FOO=bar").and(predicate::str::contains("BAZ=qux")));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn load_from_base64_stdin() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    let content = "FOO=bar\nBAZ=qux\n";
    let encoded = BASE64_STANDARD.encode(content);

    let mut cmd = Command::cargo_bin("envctl").unwrap();
    cmd.env("XDG_RUNTIME_DIR", tmp.path());
    cmd.arg("load").arg("--base64").arg("-");
    cmd.stdin(Stdio::piped());
    let mut ch = cmd.spawn().unwrap();
    use std::io::Write;
    ch.stdin
        .as_mut()
        .unwrap()
        .write_all(encoded.as_bytes())
        .unwrap();
    let out = ch.wait_with_output().unwrap();
    assert!(out.status.success());

    run_envctl(&tmp, &["list"])
        .success()
        .stdout(predicate::str::contains("FOO=bar").and(predicate::str::contains("BAZ=qux")));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn load_from_base64_invalid_payload_fails() {
    let tmp = TempDir::new().unwrap();
    let mut child = start_envd_with_runtime(&tmp);

    run_envctl(&tmp, &["load", "--base64", "not-valid!!"])
        .failure()
        .stderr(predicate::str::contains("invalid base64 payload"));

    // Ensure no vars loaded; list indicates empty state
    run_envctl(&tmp, &["list"])
        .success()
        .stdout(predicate::str::contains("No environment variables found."));

    let _ = child.kill();
    let _ = child.wait();
}
