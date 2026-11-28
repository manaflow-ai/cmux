//! The id and text checks the page's requests share: each is one Swift function of the host
//! (`AgentPaneRequest.isEditorID`, `AttachmentSource.isBundleId`, ...), with its caps.

use super::value::{count_within, is_blank};

/// A UUID as `UUID(uuidString:)` takes it: 8-4-4-4-12 hex digits, either case.
pub fn is_uuid(text: &str) -> bool {
    let mut groups = text.split('-');
    let lengths = [8usize, 4, 4, 4, 12];
    for length in lengths {
        match groups.next() {
            Some(group)
                if group.len() == length && group.bytes().all(|byte| byte.is_ascii_hexdigit()) => {}
            _ => return false,
        }
    }
    groups.next().is_none()
}

/// A Cloud environment id: `env_` and up to 64 letters, digits, `_` or `-` (5 to 68 characters).
pub fn is_cloud_environment_id(id: &str) -> bool {
    id.starts_with("env_")
        && id.len() >= 5
        && id.len() <= 68
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// A Cloud New Tab pick: an absolute path or a `github:owner/repository` without spaces.
pub fn is_cloud_pick(value: &str) -> bool {
    if !count_within(value, 4096) {
        return false;
    }
    if value.starts_with('/') {
        return true;
    }
    let Some((owner, repo)) = value.strip_prefix("github:").and_then(|path| path.split_once('/'))
    else {
        return false;
    };
    !owner.is_empty()
        && !repo.is_empty()
        && !repo.contains('/')
        && !owner.chars().chain(repo.chars()).any(char::is_whitespace)
}

/// A Connect GitHub account name consists of ASCII letters, digits and inner dashes.
pub fn is_github_owner(owner: &str) -> bool {
    (1..=39).contains(&owner.len())
        && !owner.starts_with('-')
        && !owner.ends_with('-')
        && owner.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

/// The optional repository context from the Connect GitHub card.
pub fn is_github_repo(value: &str) -> bool {
    let Some((owner, repo)) = value.split_once('/') else { return false };
    value.len() <= 140
        && is_github_owner(owner)
        && (1..=100).contains(&repo.len())
        && !matches!(repo, "." | "..")
        && repo
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// An editor id: 1 to 32 lowercase ASCII letters, digits or dashes.
pub fn is_editor_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 32
        && id.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

/// A page's one-time hand-off token: 16 to 64 ASCII letters, digits and dashes.
pub fn is_handoff_token(token: &str) -> bool {
    token.len() >= 16
        && token.len() <= 64
        && token.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

/// A bundle id: up to 255 bytes of ASCII letters, digits, `.`, `_` and `-`, with a dot and not starting with one.
pub fn is_bundle_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && value.contains('.')
        && !value.starts_with('.')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// A symbol name: lowercase words of letters and digits joined by single dots, at most 128 bytes.
pub fn is_symbol_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && name.split('.').all(|word| {
            !word.is_empty()
                && word.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
}

/// A folder the page asks to list: absolute, at most 4096 bytes, no NUL, no `..` part.
pub fn is_well_formed_folder(path: &str) -> bool {
    path.starts_with('/')
        && path.len() <= 4096
        && !path.contains('\0')
        && !path.split('/').any(|part| part == "..")
}

/// An acpmux session or tool call id: 1 to 256 ASCII letters, digits and `-_.:`, not starting with `-`.
pub fn is_token(id: &str) -> bool {
    !id.is_empty()
        && count_within(id, 256)
        && !id.starts_with('-')
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

/// A Chief's participant id: `agent_` and a short token, 7 to 64 bytes of letters, digits, `_` and `-`.
pub fn is_chief_id(chief: &str) -> bool {
    chief.starts_with("agent_")
        && chief.len() >= 7
        && chief.len() <= 64
        && chief.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// A harness id (a profile file name): 1 to 128 bytes of ASCII letters, digits, `-`, `_` and `.`.
pub fn is_harness_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

/// A hand-off session id of the store (`^[A-Za-z0-9_.:-]{1,128}$`). ICU's `$` also matches before a
/// final line terminator, as the host's regular expression did.
pub fn is_store_session(text: &str) -> bool {
    let body = strip_final_line_terminator(text);
    !body.is_empty()
        && body.len() <= 128
        && body
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b':' | b'-'))
}

fn strip_final_line_terminator(text: &str) -> &str {
    for terminator in ["\r\n", "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}", "\u{b}", "\u{c}"] {
        if let Some(body) = text.strip_suffix(terminator) {
            return body;
        }
    }
    text
}

/// A path the page names for a local file: absolute, at most 4096 bytes.
pub fn is_absolute_path(path: &str) -> bool {
    path.starts_with('/') && path.len() <= 4096
}

/// Text that is not only whitespace.
pub fn has_text(text: &str) -> bool {
    !is_blank(text)
}
