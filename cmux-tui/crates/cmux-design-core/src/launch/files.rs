//! `LaunchFrameFiles` (LaunchFrameFiles.swift): a page's launch frame file name and its owner.

/// `name(_:scale:)`: `KEY@{1...3}x.jpg`.
pub fn name(key: &str, scale: i64) -> String {
    format!("{key}@{}x.jpg", scale.clamp(1, 3))
}

/// `owner(of:)`: the key a frame file belongs to, nil for anything else (a temp file, `@4x`).
pub fn owner(file: &str) -> Option<String> {
    let stem = file.strip_suffix("x.jpg")?;
    let at = stem.rfind('@')?;
    match &stem[at + 1..] {
        "1" | "2" | "3" => Some(stem[..at].to_string()),
        _ => None,
    }
}

/// `isFileSafe(_:)`: 1 to 128 ASCII letters, digits, `_` or `-`.
pub fn is_file_safe(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 128
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
