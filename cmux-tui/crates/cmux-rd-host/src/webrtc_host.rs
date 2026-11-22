//! `cmux-screen-sharing __webrtc-host`: one WebRTC viewer's session (the iPhone's Screen Sharing
//! viewer) served under the Screen Sharing helper's grants. The app starts this helper's verified
//! copy with responsibility disclaimed, as for `serve`; this mode then runs the Swift WebRTC host
//! `cmux-screen-sharing-webrtc` (Packages/Shared/CmuxVNCWebRTC) from the same bundle's
//! `Contents/MacOS` as an ordinary child. The child's responsible process is this helper, so its
//! ScreenCaptureKit capture and the CGEvent input it posts are checked against the helper's Screen
//! Recording and Accessibility grants, never the app's. Hidden: people and agents never run it.
//!
//! The child inherits this process's stdin, stdout and stderr: the app's JSON lines
//! (CmuxVNCWebRTC ScreenHostRelay.swift) go to it untouched, and its end of file is the app's.
//!
//! SECURITY: a helper that ran any executable would hand its grants to whatever it ran. This one
//! runs only the child inside its own bundle (never a path from its arguments or environment), and
//! only after the whole bundle, the child included, verifies against the bundle's own designated
//! requirement (`codesign --verify --strict --deep`): a child swapped in the staged copy breaks the
//! seal and does not start.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The hidden mode word (CmuxNextMacScreen MacScreenWebRTCRelay.swift).
pub const MODE: &str = "__webrtc-host";
/// The Swift WebRTC host's executable, beside the helper's in `Contents/MacOS`.
pub const CHILD: &str = "cmux-screen-sharing-webrtc";

/// Runs the mode; the process exit code (the child's, 1 when it could not start, 2 for a usage error).
pub fn run(args: &[String]) -> i32 {
    if !args.is_empty() {
        eprintln!("usage: cmux-screen-sharing {MODE}");
        return 2;
    }
    let started = std::env::current_exe()
        .map_err(|e| format!("its own path: {e}"))
        .and_then(|executable| child_of(&executable))
        .and_then(|(bundle, child)| verify(&bundle).map(|()| child));
    match started {
        Ok(child) => run_child(&child),
        Err(e) => {
            eprintln!("cmux-screen-sharing {MODE}: {e}");
            1
        }
    }
}

/// The helper bundle and its WebRTC host for the helper executable `executable`
/// (`<bundle>.app/Contents/MacOS/cmux-screen-sharing`).
pub fn child_of(executable: &Path) -> Result<(PathBuf, PathBuf), String> {
    let macos = executable
        .parent()
        .filter(|dir| dir.ends_with("Contents/MacOS"))
        .ok_or_else(|| format!("{} is not inside an app bundle", executable.display()))?;
    let bundle = macos
        .parent()
        .and_then(Path::parent)
        .filter(|bundle| bundle.extension().is_some_and(|extension| extension == "app"))
        .ok_or_else(|| format!("{} is not inside an app bundle", executable.display()))?;
    let child = macos.join(CHILD);
    if !child.is_file() {
        return Err(format!(
            "this Screen Sharing helper carries no WebRTC host (Contents/MacOS/{CHILD}); \
             an iPhone viewer needs a build that bundles it"
        ));
    }
    Ok((bundle.to_path_buf(), child))
}

/// The `designated => ...` requirement in `codesign -d -r-` output.
pub fn parse_designated(output: &str) -> Option<String> {
    output
        .lines()
        .find_map(|line| line.trim().strip_prefix("designated => "))
        .map(|requirement| requirement.trim().to_owned())
        .filter(|requirement| !requirement.is_empty())
}

/// Whether `bundle` is validly signed and sealed, nested code included, and satisfies its own
/// designated requirement.
pub fn verify(bundle: &Path) -> Result<(), String> {
    let shown = Command::new("/usr/bin/codesign")
        .args(["-d", "-r-"])
        .arg(bundle)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("codesign: {e}"))?;
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&shown.stdout),
        String::from_utf8_lossy(&shown.stderr)
    );
    let requirement = parse_designated(&text)
        .filter(|_| shown.status.success())
        .ok_or_else(|| format!("the helper's signature: {}", text.trim()))?;
    let checked = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "--deep", "-R"])
        .arg(format!("={requirement}"))
        .arg(bundle)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("codesign: {e}"))?;
    if checked.status.success() {
        Ok(())
    } else {
        Err(format!(
            "the helper's WebRTC host did not verify: {}",
            String::from_utf8_lossy(&checked.stderr).trim()
        ))
    }
}

/// Runs `child` on this process's stdio (no responsibility disclaimed: the helper stays
/// responsible) and returns its exit code; a child ended by a signal reads as 128 + the signal.
pub fn run_child(child: &Path) -> i32 {
    match Command::new(child)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
    {
        Ok(status) => status.code().unwrap_or_else(|| {
            use std::os::unix::process::ExitStatusExt;
            128 + status.signal().unwrap_or(0)
        }),
        Err(e) => {
            eprintln!("cmux-screen-sharing {MODE}: {} did not start: {e}", child.display());
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh `<name>.app/Contents/MacOS` under the temp dir, removed when dropped.
    struct Bundle(PathBuf);

    impl Bundle {
        fn new(tag: &str) -> Self {
            let root =
                std::env::temp_dir().join(format!("cmux-webrtc-host-{tag}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(root.join("Helper Screen Sharing.app/Contents/MacOS")).unwrap();
            Self(root)
        }
        fn app(&self) -> PathBuf {
            self.0.join("Helper Screen Sharing.app")
        }
        fn executable(&self) -> PathBuf {
            self.app().join("Contents/MacOS/cmux-screen-sharing")
        }
    }

    impl Drop for Bundle {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn extra_arguments_are_refused_before_anything_starts() {
        assert_eq!(run(&["/bin/sh".into()]), 2);
    }

    #[test]
    fn the_child_is_the_one_beside_the_helper_in_its_own_bundle() {
        let bundle = Bundle::new("found");
        std::fs::write(bundle.app().join("Contents/MacOS").join(CHILD), b"").unwrap();
        let (app, child) = child_of(&bundle.executable()).unwrap();
        assert_eq!(app, bundle.app());
        assert_eq!(child, bundle.app().join("Contents/MacOS/cmux-screen-sharing-webrtc"));
    }

    #[test]
    fn a_helper_without_the_child_or_outside_a_bundle_says_so() {
        let bundle = Bundle::new("missing");
        let missing = child_of(&bundle.executable()).unwrap_err();
        assert!(missing.contains("carries no WebRTC host"), "{missing}");
        let loose = child_of(Path::new("/usr/local/bin/cmux-screen-sharing")).unwrap_err();
        assert!(loose.contains("not inside an app bundle"), "{loose}");
        let not_app =
            child_of(Path::new("/tmp/Folder/Contents/MacOS/cmux-screen-sharing")).unwrap_err();
        assert!(not_app.contains("not inside an app bundle"), "{not_app}");
    }

    #[test]
    fn the_designated_requirement_is_read_from_codesign_output() {
        let output = "Executable=/x/Contents/MacOS/cmux-screen-sharing\n\
                      designated => identifier \"com.cmuxterm.app.nightly.screen-sharing\" and anchor apple generic\n";
        assert_eq!(
            parse_designated(output).as_deref(),
            Some("identifier \"com.cmuxterm.app.nightly.screen-sharing\" and anchor apple generic")
        );
        assert_eq!(parse_designated("code object is not signed at all"), None);
        assert_eq!(parse_designated("designated => \n"), None);
    }

    #[test]
    fn an_unsigned_bundle_never_starts_its_child() {
        let bundle = Bundle::new("unsigned");
        std::fs::write(bundle.app().join("Contents/MacOS").join(CHILD), b"#!/bin/sh\nexit 0\n")
            .unwrap();
        assert!(verify(&bundle.app()).is_err());
    }

    #[test]
    fn the_childs_exit_code_is_the_modes() {
        assert_eq!(run_child(Path::new("/usr/bin/true")), 0);
        assert_eq!(run_child(Path::new("/usr/bin/false")), 1);
        assert_eq!(run_child(Path::new("/nonexistent/cmux-screen-sharing-webrtc")), 1);
    }
}
