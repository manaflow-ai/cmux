//! Which paths under /app/ are NEXT pane files. Shared by app_assets.rs (serving) and
//! build.rs (what to embed), through `#[path]`, so the two cannot disagree.

/// No URL decoding or directory browsing: only the production builder's output.
pub fn asset(path: &str) -> Option<(&str, &'static str)> {
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
                || !name.ends_with(".js")
            {
                return None;
            }
            "text/javascript; charset=utf-8"
        }
    };
    Some((relative, kind))
}
