//! What a PTY child's environment ends up being: tests that read it from a
//! real child rather than from the builder.

use super::*;

/// `env_remove` keeps a key from the child even when the spawning process
/// has it, so a terminal child never inherits what the daemon carries
/// (cmux#22585: `TERM_PROGRAM_VERSION`, [`UNSET_IN_TERMINAL_CHILDREN`]). The
/// PTY child prints its own value, so this measures the spawned environment,
/// not the builder.
///
/// The inherited value is installed in a re-executed copy of this test binary
/// (`PROBE`) rather than with `set_var` here: this process's environment is
/// shared with every other test running in parallel.
#[test]
fn env_remove_drops_an_inherited_value_from_the_child() -> Result<(), Box<dyn std::error::Error>> {
    const KEY: &str = "CMUX_PTY_ENV_REMOVE_PROBE";
    const PROBE: &str = "CMUX_PTY_ENV_REMOVE_PROBE_PARENT";
    const NAME: &str = "env_tests::env_remove_drops_an_inherited_value_from_the_child";
    if std::env::var_os(PROBE).is_some() {
        assert_eq!(
            std::env::var(KEY).as_deref(),
            Ok("inherited"),
            "the probe parent must carry the key it is testing inheritance of"
        );
        let pair = open(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })?;
        let mut command = PtyCommand::new("/bin/sh");
        command.args(["-c".to_string(), format!("printf 'probe:[%s]' \"${{{KEY}:-}}\"")]);
        // Set then removed: the removal wins over this command's own value as
        // well as over the inherited one.
        command.env(KEY, "set-then-removed");
        command.env_remove(KEY);
        let mut spawned = pair.spawn(command)?;
        let mut reader = spawned.master.try_clone_reader()?;
        let mut output = Vec::new();
        let mut buffer = [0u8; 1024];
        while let Ok(count) = io::Read::read(&mut reader, &mut buffer) {
            if count == 0 {
                break;
            }
            output.extend_from_slice(&buffer[..count]);
            if output.windows(7).any(|window| window == b"probe:[") && output.ends_with(b"]") {
                break;
            }
        }
        let _ = spawned.child.wait();
        println!("{}", String::from_utf8_lossy(&output).trim());
        return Ok(());
    }
    let output = std::process::Command::new(std::env::current_exe()?)
        .args(["--exact", NAME, "--nocapture", "--test-threads=1"])
        .env(PROBE, "1")
        .env(KEY, "inherited")
        .output()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    // An absent marker is a failure, never a pass: the probe must have spawned
    // a child and read its environment back.
    let probed = stdout
        .lines()
        .find_map(|line| line.split("probe:").nth(1))
        .ok_or_else(|| format!("the probe child printed no environment: {stdout}{stderr}"))?;
    assert_eq!(probed.trim(), "[]", "the child kept the removed key: {stdout}{stderr}");
    Ok(())
}
