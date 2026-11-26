//! Paths as Foundation's `URL.path` writes them, so a Rust rule names the same file as the Swift it replaces.

/// `URL(fileURLWithPath:).standardizedFileURL.path`: `.` dropped, `..` pops, no doubled or trailing `/`.
pub(crate) fn standardized(path: &str) -> String {
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|last| *last != "..") {
                    parts.pop();
                } else if !absolute {
                    parts.push("..");
                }
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("/");
    if absolute { format!("/{joined}") } else { joined }
}

/// `appendingPathComponent(_:)`: `base/component`, without a trailing `/`.
pub(crate) fn join(base: &str, component: &str) -> String {
    let component = component.trim_end_matches('/');
    if base.is_empty() {
        component.to_owned()
    } else if base.ends_with('/') {
        format!("{base}{component}")
    } else {
        format!("{base}/{component}")
    }
}

/// `deletingLastPathComponent().path`.
pub(crate) fn parent(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) => "/".to_owned(),
        Some(index) => trimmed.get(..index).unwrap_or_default().to_owned(),
        None => String::new(),
    }
}

/// `lastPathComponent`.
pub(crate) fn last_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}
