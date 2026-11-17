//! The launch record's name for a published image: `<build>/<window key>/<generation>`
//! (cmux-launch-record v2 `image_key`). The stage-0 launch window (cmux-launch-shell `ImageKey`)
//! parses it, refuses another build's image, and opens `<image dir>/<window key>.<generation>.png`
//! itself, the file [`crate::Store::publish`] wrote. A record never carries a path.

use crate::window_key;

/// The longest key component (cmux-launch-shell `ImageKey`).
pub const MAX_COMPONENT: usize = 128;

/// The build part of every key, from the bundle's `CFBundleVersion` and `CMUXCommit`: joined with
/// `+`, kept to ASCII letters, digits and `.+_-`, at most [`MAX_COMPONENT`] bytes; `unknown` when
/// nothing is left. The same rule as the stage-0 window's `LaunchShellPaths.build(info:)`, so a new
/// build never draws an old build's image.
pub fn build_name(version: Option<&str>, commit: Option<&str>) -> String {
    let raw = [version, commit].into_iter().flatten().collect::<Vec<_>>().join("+");
    let kept: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '+' | '_' | '-'))
        .take(MAX_COMPONENT)
        .collect();
    if kept.is_empty() { "unknown".to_owned() } else { kept }
}

/// `<build>/<window_key(window_id)>/<generation>`; `None` when `build` is not one key component
/// (empty, `.`, `..`, over [`MAX_COMPONENT`] bytes, or a byte outside `[A-Za-z0-9._+-]`) or the
/// window id is empty.
pub fn record_key(build: &str, window_id: &str, generation: u64) -> Option<String> {
    if window_id.is_empty() || !is_component(build) {
        return None;
    }
    Some(format!("{build}/{}/{generation}", window_key(window_id)))
}

fn is_component(s: &str) -> bool {
    !s.is_empty()
        && s != "."
        && s != ".."
        && s.len() <= MAX_COMPONENT
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'+'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_name_is_the_stage_zero_rule() {
        // The stage-0 window's own cases (LaunchShellTests).
        assert_eq!(build_name(Some("4294"), Some("abc123")), "4294+abc123");
        assert_eq!(build_name(Some("1/../2 x"), None), "1..2x");
        assert_eq!(build_name(None, None), "unknown");
        assert_eq!(build_name(Some("é/"), None), "unknown");
        assert_eq!(build_name(Some(&"9".repeat(300)), None).len(), MAX_COMPONENT);
    }

    #[test]
    fn a_key_names_the_window_and_generation_never_a_path() {
        assert_eq!(record_key("4294+abc", "front", 3).as_deref(), Some("4294+abc/front/3"));
        let key = record_key("1", "a/b", 7).unwrap();
        assert_eq!(key, format!("1/{}/7", window_key("a/b")));
        assert_eq!(key.split('/').count(), 3);
        assert_eq!(record_key("", "w", 1), None);
        assert_eq!(record_key("..", "w", 1), None);
        assert_eq!(record_key("a/b", "w", 1), None);
        assert_eq!(record_key("1", "", 1), None);
    }
}
