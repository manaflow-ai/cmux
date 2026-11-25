use std::time::Duration;

/// Best effort and noninteractive: hosting stays available when logind refuses the grant.
pub(crate) fn enable_linger() -> String {
    let enabled = cmux_process::Command::new("loginctl")
        .args(["--no-ask-password", "enable-linger"])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .ok()
        .is_some_and(|mut child| match child.wait_timeout(Duration::from_secs(5)) {
            Ok(Some(status)) => status.success(),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                false
            }
        });
    linger_note(enabled).to_owned()
}

fn linger_note(enabled: bool) -> &'static str {
    if enabled {
        "linger enabled: hosting survives logout"
    } else {
        "linger could not be enabled; run `sudo loginctl enable-linger $USER` so hosting survives logout"
    }
}
