//! Any file attaches (Lawrence 2026-10-20, "“index.html” can't be attached ... need to fix
//! this"): UTF-8 text goes as `text/plain` whatever its name, other bytes as
//! `application/octet-stream`; the local owner takes both under any valid name, as the cloud
//! owner (`home-core` attachments.ts) does.

use cmux_conversation::{AttachmentClass, validate_attachment_meta};

const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn check(name: &str, mime: &str) -> Result<AttachmentClass, cmux_conversation::AttachmentReject> {
    validate_attachment_meta(HASH, mime, 1_234, name, None, None, None)
}

#[test]
fn text_of_any_name_attaches() {
    for name in ["index.html", "run.sh", "app.js", "logo.svg", "setup.exe", "Makefile", ".zshrc"] {
        assert_eq!(check(name, "text/plain"), Ok(AttachmentClass::File), "{name}");
    }
}

#[test]
fn any_binary_attaches_as_a_generic_file() {
    for name in ["state.sqlite", "blob", "firmware.bin", "Setup.dmg"] {
        assert_eq!(check(name, "application/octet-stream"), Ok(AttachmentClass::File), "{name}");
    }
}

#[test]
fn active_types_a_client_never_sends_stay_refused() {
    assert!(check("x.svg", "image/svg+xml").is_err());
    assert!(check("index.html", "text/html").is_err());
}
