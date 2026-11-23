//! A fresh permission snapshot for the process responsible for this one, and the one request
//! that asks macOS for a grant. On a Mac the app runs both from the Screen Sharing helper
//! (`<app> Helper.app`, started with responsibility disclaimed;
//! plans/cmux-next/screen-sharing-helper.md), so macOS checks and names the helper, never the
//! app: a grant restarts at most the helper, never cmux. A fresh process each time, because a
//! running one can keep an old Screen Recording answer after the person changes it.
//! `permissions` creates no capture session, posts no input and never requests permission;
//! `request-permission` asks for exactly the one grant named, then prints the same snapshot.

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

/// The System Settings item that holds this process's Screen Recording grant: the innermost
/// app bundle around `executable` (`cmux NIGHTLY Screen Sharing.app/Contents/MacOS/...` is
/// "cmux NIGHTLY Screen Sharing"), else the one holder the handbook names, "cmux Computer Use"
/// (cmuxterm-hq docs/handbook/screen-share-grant-lost-on-a-fleet-mac.md).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn listed_as(executable: &std::path::Path) -> String {
    executable
        .ancestors()
        .filter_map(|p| p.file_name()?.to_str()?.strip_suffix(".app"))
        .next()
        .unwrap_or("cmux Computer Use")
        .to_owned()
}

/// This Mac's short name (`cosmic-gray.local` is `cosmic-gray`), for the words a viewer reads.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn host_name() -> String {
    let name = kernel_host_name();
    let short = name.strip_suffix(".local").unwrap_or(&name);
    if short.is_empty() {
        "this Mac".into()
    } else {
        short.to_owned()
    }
}

#[cfg(unix)]
fn kernel_host_name() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most `buf.len()` bytes into our own buffer.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    if ok {
        String::from_utf8_lossy(&buf[..end]).into_owned()
    } else {
        String::new()
    }
}

/// Windows has no `gethostname` in libc: the computer name Settings > System shows.
#[cfg(not(unix))]
fn kernel_host_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_default().trim().to_owned()
}

/// The reason a share ends with when Screen Recording is not granted: the cause, the Mac and
/// the one click that fixes it (a person's; nothing here grants anything).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn screen_recording_missing(host: &str, item: &str) -> String {
    format!(
        "Screen Recording not granted on {host}. On {host}, open System Settings > Privacy & \
         Security > Screen & System Audio Recording and turn on \"{item}\"."
    )
}

/// The reason a share ends with when Screen Recording reads as on but macOS lists no display to
/// capture (an empty SCShareableContent): a grant macOS holds for an older copy of the item.
/// Its own words, so it is never read as a missing grant or a helper that stopped.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn no_display_listed(host: &str, item: &str) -> String {
    format!(
        "Screen Recording is on for \"{item}\" on {host}, but macOS listed no display to capture. \
         On {host}, open System Settings > Privacy & Security > Screen & System Audio Recording, \
         turn \"{item}\" off and on again."
    )
}

/// [`no_display_listed`] for this process on this Mac.
#[cfg(target_os = "macos")]
pub(crate) fn no_display_here() -> String {
    let exe = std::env::current_exe().unwrap_or_default();
    no_display_listed(&host_name(), &listed_as(&exe))
}

/// At capture start: Err with [`screen_recording_missing`] when this process (the helper, its
/// own responsible process) has no Screen Recording grant, so the session ends with the cause
/// on the wire (`ended: failed: <words>`) instead of a capture that never delivers a picture.
/// Ok when it is granted or cannot be read (the capture then says what it saw).
#[cfg(target_os = "macos")]
pub(crate) fn require_screen_recording() -> Res<()> {
    if platform::cg::available().is_err() {
        return Ok(());
    }
    // SAFETY: resolved above; no arguments, returns a plain bool, never prompts.
    if unsafe { platform::cg::CGPreflightScreenCaptureAccess() } {
        return Ok(());
    }
    let exe = std::env::current_exe().unwrap_or_default();
    Err(screen_recording_missing(&host_name(), &listed_as(&exe)).into())
}

/// One grant `request-permission` may ask for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Grant {
    ScreenRecording,
    Accessibility,
}

impl Grant {
    pub(crate) fn parse(word: &str) -> Option<Self> {
        match word {
            "screen-recording" => Some(Self::ScreenRecording),
            "accessibility" => Some(Self::Accessibility),
            _ => None,
        }
    }
}

/// `request-permission screen-recording|accessibility`: macOS's own prompt for this one grant
/// (macOS shows it at most once per grant; after that the caller opens System Settings), then
/// the snapshot. The person still answers macOS: nothing here grants anything.
pub(crate) fn run_request(grant: Grant) -> Res<()> {
    request(grant)?;
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
fn request(grant: Grant) -> Res<()> {
    use platform::{ax, cf, cg};
    match grant {
        Grant::ScreenRecording => {
            cg::available()?;
            // SAFETY: resolved above; no arguments, returns a plain bool (false until the
            // person grants it, including on the call that shows the prompt).
            let _ = unsafe { cg::CGRequestScreenCaptureAccess() };
        }
        Grant::Accessibility => {
            ax::available()?;
            cf::available()?;
            // SAFETY: every symbol is resolved above. The key and the dictionary are made
            // here and released below; kCFBooleanTrue is a constant CoreFoundation owns.
            unsafe {
                let key = cf::CFStringCreateWithCString(
                    std::ptr::null(),
                    c"AXTrustedCheckOptionPrompt".as_ptr(),
                    platform::CF_STRING_ENCODING_UTF8,
                );
                if key.is_null() {
                    return Err("could not make the Accessibility prompt option".into());
                }
                let keys = [key];
                let values = [cf::kCFBooleanTrue()];
                let options = cf::CFDictionaryCreate(
                    std::ptr::null(),
                    keys.as_ptr(),
                    values.as_ptr(),
                    1,
                    cf::kCFTypeDictionaryKeyCallBacks(),
                    cf::kCFTypeDictionaryValueCallBacks(),
                );
                cf::CFRelease(key);
                if options.is_null() {
                    return Err("could not make the Accessibility prompt options".into());
                }
                let _ = ax::AXIsProcessTrustedWithOptions(options);
                cf::CFRelease(options);
            }
        }
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn request(_grant: Grant) -> Res<()> {
    Err("permission requests are supported only on macOS".into())
}

#[cfg(target_os = "macos")]
mod platform {
    use cmux_encode::framework;
    pub(super) use std::ffi::{c_char, c_void};

    /// kCFStringEncodingUTF8.
    pub(super) const CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    framework! {
        pub mod cg = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics" {
            fn CGPreflightScreenCaptureAccess() -> bool;
            fn CGRequestScreenCaptureAccess() -> bool;
        }
    }

    framework! {
        pub mod ax = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices" {
            fn AXIsProcessTrusted() -> u8;
            fn AXIsProcessTrustedWithOptions(options: *const c_void) -> u8;
        }
    }

    framework! {
        pub mod cf = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" {
            static kCFBooleanTrue: *const c_void;
            ref kCFTypeDictionaryKeyCallBacks: c_void;
            ref kCFTypeDictionaryValueCallBacks: c_void;
            fn CFStringCreateWithCString(allocator: *const c_void, text: *const c_char, encoding: u32) -> *const c_void;
            fn CFDictionaryCreate(
                allocator: *const c_void,
                keys: *const *const c_void,
                values: *const *const c_void,
                count: isize,
                key_callbacks: *const c_void,
                value_callbacks: *const c_void,
            ) -> *const c_void;
            fn CFRelease(value: *const c_void);
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

    #[test]
    fn a_request_names_exactly_one_known_grant() {
        assert_eq!(Grant::parse("screen-recording"), Some(Grant::ScreenRecording));
        assert_eq!(Grant::parse("accessibility"), Some(Grant::Accessibility));
        for word in ["", "all", "screen_recording", "Accessibility", "camera"] {
            assert_eq!(Grant::parse(word), None, "{word}");
        }
        assert_eq!(crate::run_cli(&["request-permission".into()]), 2);
        assert_eq!(crate::run_cli(&["request-permission".into(), "camera".into()]), 2);
        let two = ["request-permission".into(), "accessibility".into(), "screen-recording".into()];
        assert_eq!(crate::run_cli(&two), 2);
    }

    #[test]
    fn a_missing_screen_recording_grant_names_the_mac_and_the_item_to_turn_on() {
        use std::path::Path;
        let old = Path::new(
            "/Applications/cmux NIGHTLY.app/Contents/Library/cmux NIGHTLY Screen Sharing.app/Contents/MacOS/cmux-screen-sharing",
        );
        assert_eq!(listed_as(old), "cmux NIGHTLY Screen Sharing");
        let cua =
            Path::new("/Applications/cmux Computer Use.app/Contents/MacOS/cmux-screen-sharing");
        assert_eq!(listed_as(cua), "cmux Computer Use");
        assert_eq!(listed_as(Path::new("/usr/local/bin/cmux-rd")), "cmux Computer Use");
        let words = screen_recording_missing("cosmic-gray", "cmux Computer Use");
        assert!(words.starts_with("Screen Recording not granted on cosmic-gray."), "{words}");
        assert!(words.contains(
            "System Settings > Privacy & Security > Screen & System Audio Recording and turn on \"cmux Computer Use\""
        ));
        assert!(!host_name().is_empty());
    }

    #[test]
    fn a_grant_that_lists_no_display_is_its_own_cause() {
        let words = no_display_listed("cosmic-gray", "cmux NIGHTLY Screen Sharing");
        assert!(words.contains("macOS listed no display to capture"), "{words}");
        assert!(words.contains("turn \"cmux NIGHTLY Screen Sharing\" off and on again"), "{words}");
        assert!(!words.contains("not granted"), "never read as a missing grant: {words}");
    }

    #[test]
    fn a_launch_services_open_is_recognized_only_inside_a_bundle() {
        use std::path::Path;
        let helper = Path::new("/x/cmux Helper.app/Contents/MacOS/cmux-screen-sharing");
        let cli = Path::new("/usr/local/bin/cmux-rd");
        assert!(crate::is_launch_services_open(&[], helper));
        assert!(crate::is_launch_services_open(&["-psn_0_1234".into()], helper));
        assert!(!crate::is_launch_services_open(&["serve".into()], helper));
        assert!(!crate::is_launch_services_open(&[], cli));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn permission_probe_unsupported_platform_emits_no_snapshot() {
        let mut output = Vec::new();
        assert!(write_snapshot(&mut output, read()).is_err());
        assert!(output.is_empty());
    }
}
