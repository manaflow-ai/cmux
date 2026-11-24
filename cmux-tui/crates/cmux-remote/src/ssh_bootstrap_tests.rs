use super::*;

/// The login shell must see exactly `sh`, `-c` and the unchanged script,
/// including a script that itself contains single quotes.
#[cfg(unix)]
#[test]
fn posix_shell_command_hands_sh_the_exact_script() {
    let script = "rc=0; { printf '%s|' \"a b\" $rc; }; [ \"$rc\" -eq 0 ] || exit 1";
    let output = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!(
            "set -- {}; printf '%s\\n' \"$#\" \"$1\" \"$2\" \"$3\"",
            posix_shell_command(script)
        ))
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&output.stdout), format!("3\nsh\n-c\n{script}\n"));
    let output = std::process::Command::new("sh")
        .arg("-c")
        .arg(posix_shell_command(script))
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout, b"a b|0|");
}
