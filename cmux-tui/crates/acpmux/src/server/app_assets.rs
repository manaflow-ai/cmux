//! The shipped NEXT pane, on the existing listener. These static files contain no
//! credentials: the URL fragment supplies a scoped browser capability
//! to the browser transport. Host/Origin checks run before this module is called.
use std::path::{Path, PathBuf};

type Response = (&'static str, Vec<u8>, &'static str);

fn missing() -> Response {
    ("404 Not Found", b"not found".to_vec(), "text/plain")
}

#[path = "app_asset_paths.rs"]
mod paths;
use paths::asset;

include!(concat!(env!("OUT_DIR"), "/browser_app_assets.rs"));

/// A standalone distribution can put agent-pane beside its binary, or point at
/// the output of build-agent-pane-web.sh. The app uses its existing SPM resource
/// bundle; no checkout, Vite host, current directory or other app is searched.
fn roots(exe: &Path, configured: Option<PathBuf>) -> Vec<PathBuf> {
    if let Some(root) = configured {
        return vec![root];
    }
    let Some(bin) = exe.parent() else { return Vec::new() };
    let mut roots = vec![bin.join("agent-pane")];
    if let Some(parent) = bin.parent() {
        let bundle = parent.join("CmuxNext_CmuxNextAgentPane.bundle");
        roots.push(bundle.join("Contents/Resources/agent-pane"));
        roots.push(bundle.join("agent-pane"));
        roots.push(parent.join("share/acpmux/agent-pane"));
    }
    roots
}

pub(super) async fn serve(path: &str) -> Response {
    let Some((relative, kind)) = asset(path) else { return missing() };
    // Native pages may paint a saved chat before connecting. A fresh browser
    // page has none; answer the same script path without disclosing any state.
    if relative == "__snapshot/chat.js" {
        return ("200 OK", Vec::new(), kind);
    }
    let exe = std::env::current_exe().unwrap_or_default();
    let configured = std::env::var_os("ACPMUX_APP_ASSETS_DIR").map(PathBuf::from);
    if configured.is_none() && !SHIPPED.is_empty() {
        return shipped(relative, kind);
    }
    for root in roots(&exe, configured) {
        if tokio::fs::metadata(root.join("index.html")).await.is_ok_and(|m| m.is_file()) {
            return read(&root, relative, kind).await;
        }
    }
    (
        "503 Service Unavailable",
        b"NEXT pane assets are not installed with this daemon".to_vec(),
        "text/plain",
    )
}

fn shipped(relative: &str, kind: &'static str) -> Response {
    let Some((_, packed)) = SHIPPED
        .binary_search_by_key(&relative, |(name, _)| *name)
        .ok()
        .and_then(|index| SHIPPED.get(index))
    else {
        return missing();
    };
    let mut body = packed.inflate();
    if relative == "index.html" {
        body = body.replace("connect-src 'none'", "connect-src 'self'");
    }
    ("200 OK", body.into_bytes(), kind)
}

/// Suffix of a chunk the app build stores raw-deflated (CMUX-570, app size):
/// scripts/cmux-next/pack-webviews-chunks.py replaces the app copy's
/// `chunks/<name>` by `chunks/<name>.deflate`.
const PACKED_SUFFIX: &str = ".deflate";
/// The largest a packed chunk may inflate to (the read limit of a plain file).
const MAX_ASSET_BYTES: u64 = 32 * 1024 * 1024;

async fn read(root: &Path, relative: &str, kind: &'static str) -> Response {
    let Ok(root) = tokio::fs::canonicalize(root).await else { return missing() };
    let Ok(file) = tokio::fs::canonicalize(root.join(relative)).await else {
        return read_packed(&root, relative, kind).await;
    };
    if !file.starts_with(&root) {
        return missing();
    }
    let Ok(meta) = tokio::fs::metadata(&file).await else { return missing() };
    if !meta.is_file() || meta.len() > MAX_ASSET_BYTES {
        return missing();
    }
    let Ok(mut body) = tokio::fs::read(file).await else { return missing() };
    if relative == "index.html" {
        let Ok(html) = String::from_utf8(body) else { return missing() };
        // The native resource remains unchanged. Only the browser's copy may
        // connect to its own listener; it gets no arbitrary network access.
        body = html.replace("connect-src 'none'", "connect-src 'self'").into_bytes();
    }
    ("200 OK", body, kind)
}

/// A file the folder holds only packed (`<relative>.deflate` beside where it
/// would be), inflated in memory. The packed copy must be a regular file below
/// `root` whose real name is the file's name plus the suffix, as for a plain
/// file; one that does not inflate within the limit is a 404.
async fn read_packed(root: &Path, relative: &str, kind: &'static str) -> Response {
    let wanted = root.join(format!("{relative}{PACKED_SUFFIX}"));
    let Ok(packed) = tokio::fs::canonicalize(&wanted).await else { return missing() };
    if !packed.starts_with(root) || packed.file_name() != wanted.file_name() {
        return missing();
    }
    let Ok(meta) = tokio::fs::metadata(&packed).await else { return missing() };
    if !meta.is_file() || meta.len() > MAX_ASSET_BYTES {
        return missing();
    }
    let Ok(stored) = tokio::fs::read(packed).await else { return missing() };
    let mut body = Vec::new();
    let inflated = std::io::Read::read_to_end(
        &mut std::io::Read::take(
            flate2::read::DeflateDecoder::new(stored.as_slice()),
            MAX_ASSET_BYTES + 1,
        ),
        &mut body,
    );
    if inflated.is_err() || body.len() as u64 > MAX_ASSET_BYTES {
        return missing();
    }
    ("200 OK", body, kind)
}

#[cfg(test)]
#[path = "app_assets_tests.rs"]
mod tests;
