//! A fresh, read-only permission snapshot for the process responsible for launching this CLI.
//! The app launches this exactly as it launches `rd serve`: a long-running app can retain an
//! old Screen Recording preflight answer after the person changes the grant in System Settings.
//! No capture session is created, no input is posted, and neither query requests permission.

use crate::Res;
use serde::Serialize;
use std::io::Write;

#[derive(Serialize)]
struct Permissions {
    screen_recording: bool,
    accessibility: bool,
}

pub(crate) fn run() -> Res<()> {
    write_snapshot(&mut std::io::stdout().lock(), read())
}

fn write_snapshot(output: &mut impl Write, result: Res<Permissions>) -> Res<()> {
    // Failed framework/symbol lookup is an error, never a fabricated permission snapshot.
    let snapshot = result?;
    serde_json::to_writer(&mut *output, &snapshot)?;
    output.write_all(b"\n")?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn read() -> Res<Permissions> {
    platform::cg::available()?;
    platform::ax::available()?;
    // SAFETY: both no-argument queries are resolved above and return plain C values.
    // AXIsProcessTrusted returns Apple's Boolean (UInt8), whereas CoreGraphics uses bool.
    Ok(unsafe {
        Permissions {
            screen_recording: platform::cg::CGPreflightScreenCaptureAccess(),
            accessibility: platform::ax::AXIsProcessTrusted() != 0,
        }
    })
}

#[cfg(not(target_os = "macos"))]
fn read() -> Res<Permissions> {
    Err("permission probing is supported only on macOS".into())
}

#[cfg(target_os = "macos")]
mod platform {
    use cmux_encode::framework;

    framework! {
        pub mod cg = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics" {
            fn CGPreflightScreenCaptureAccess() -> bool;
        }
    }

    framework! {
        pub mod ax = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices" {
            fn AXIsProcessTrusted() -> u8;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permission_probe_read_failure_emits_no_snapshot() {
        let mut output = Vec::new();
        let result = write_snapshot(&mut output, Err("framework unavailable".into()));
        assert!(result.is_err());
        assert!(output.is_empty());
    }

    #[test]
    fn permission_probe_snapshot_keeps_grants_independent() {
        for (screen_recording, accessibility) in [(true, false), (false, true)] {
            let mut output = Vec::new();
            write_snapshot(&mut output, Ok(Permissions { screen_recording, accessibility }))
                .expect("snapshot");
            let value: serde_json::Value = serde_json::from_slice(&output).expect("JSON");
            assert_eq!(value["screen_recording"], screen_recording);
            assert_eq!(value["accessibility"], accessibility);
            assert_eq!(output.last(), Some(&b'\n'));
        }
    }

    #[test]
    fn permission_probe_rejects_options_that_could_imply_prompting() {
        assert_eq!(crate::run_cli(&["permissions".into(), "--request".into(), "1".into()]), 2);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn permission_probe_unsupported_platform_emits_no_snapshot() {
        let mut output = Vec::new();
        assert!(write_snapshot(&mut output, read()).is_err());
        assert!(output.is_empty());
    }
}
