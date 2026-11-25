//! The URL paths `/app/` serves, shared by `app_assets.rs` and `build.rs`, which embeds
//! only files this accepts. It depends on nothing else in the crate, so the build script
//! can include it with `#[path]`.

/// No URL decoding or directory browsing: only the production builder's output.
/// Returns the path relative to the pane root and its content type.
pub(crate) fn asset(path: &str) -> Option<(&str, &'static str)> {
    let relative = path.strip_prefix("/app/")?;
    let relative = if relative.is_empty() { "index.html" } else { relative };
    let kind = match relative {
        "index.html" => "text/html; charset=utf-8",
        "pane.css" | "pane-copy.css" => "text/css; charset=utf-8",
        "pane.js"
        | "highlight-worker.js"
        | "image-worker.js"
        | "chat-snapshot.js"
        | "__snapshot/chat.js" => "text/javascript; charset=utf-8",
        _ => {
            let (directory, name) = relative.split_once('/')?;
            if !matches!(directory, "chunks" | "locales")
                || name.starts_with('.')
                || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
            {
                return None;
            }
            // The split bundle also writes a stylesheet beside a chunk that imports one.
            match name.rsplit_once('.') {
                Some((_, "js")) => "text/javascript; charset=utf-8",
                Some((_, "css")) if directory == "chunks" => "text/css; charset=utf-8",
                _ => return None,
            }
        }
    };
    Some((relative, kind))
}
