//! The shipped NEXT pane, on the existing listener. These static files contain no
//! credentials: the URL fragment supplies a scoped browser capability
//! to the browser transport. Host/Origin checks run before this module is called.
use std::path::{Path, PathBuf};

#[path = "app_asset_paths.rs"]
mod paths;
use paths::asset;

/// What build.rs embedded (empty unless ACPMUX_BUNDLED_APP_ASSETS_DIR was set at build time).
mod bundled {
    include!(concat!(env!("OUT_DIR"), "/app_bundle.rs"));
}

type Bundle = &'static [(&'static str, cmux_embed::PackedStr)];

type Response = (&'static str, Vec<u8>, &'static str);

fn missing() -> Response {
    ("404 Not Found", b"not found".to_vec(), "text/plain")
}

/// The lookup order: ACPMUX_APP_ASSETS_DIR, then a directory beside the binary, then the
/// bundle embedded at build time. A standalone distribution can put agent-pane beside its
/// binary, or point at the output of build-agent-pane-web.sh. The app uses its existing SPM resource
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
    let exe = std::env::current_exe().unwrap_or_default();
    let configured = std::env::var_os("ACPMUX_APP_ASSETS_DIR").map(PathBuf::from);
    serve_from(path, &exe, configured, bundled::BUNDLE).await
}

async fn serve_from(
    path: &str,
    exe: &Path,
    configured: Option<PathBuf>,
    bundle: Bundle,
) -> Response {
    let Some((relative, kind)) = asset(path) else { return missing() };
    // Native pages may paint a saved chat before connecting. A fresh browser
    // page has none; answer the same script path without disclosing any state.
    if relative == "__snapshot/chat.js" {
        return ("200 OK", Vec::new(), kind);
    }
    for root in roots(exe, configured) {
        if tokio::fs::metadata(root.join("index.html")).await.is_ok_and(|m| m.is_file()) {
            return read(&root, relative, kind).await;
        }
    }
    if bundle.iter().any(|(name, _)| *name == "index.html") {
        return match bundle.iter().find(|(name, _)| *name == relative) {
            Some((_, text)) => finish(relative, text.inflate().into_bytes(), kind),
            None => missing(),
        };
    }
    (
        "503 Service Unavailable",
        b"NEXT pane assets are not installed with this daemon".to_vec(),
        "text/plain",
    )
}

async fn read(root: &Path, relative: &str, kind: &'static str) -> Response {
    let Ok(root) = tokio::fs::canonicalize(root).await else { return missing() };
    let Ok(file) = tokio::fs::canonicalize(root.join(relative)).await else { return missing() };
    if !file.starts_with(&root) {
        return missing();
    }
    let Ok(meta) = tokio::fs::metadata(&file).await else { return missing() };
    if !meta.is_file() || meta.len() > 32 * 1024 * 1024 {
        return missing();
    }
    let Ok(body) = tokio::fs::read(file).await else { return missing() };
    finish(relative, body, kind)
}

/// The same headers' worth of rewriting for a file from disk and one from the bundle.
fn finish(relative: &str, mut body: Vec<u8>, kind: &'static str) -> Response {
    if relative == "index.html" {
        let Ok(html) = String::from_utf8(body) else { return missing() };
        // The native resource remains unchanged. Only the browser's copy may
        // connect to its own listener; it gets no arbitrary network access.
        body = html.replace("connect-src 'none'", "connect-src 'self'").into_bytes();
    }
    ("200 OK", body, kind)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packed(text: &str) -> cmux_embed::PackedStr {
        let bytes: &'static [u8] =
            Box::leak(zstd::bulk::compress(text.as_bytes(), 3).unwrap().into_boxed_slice());
        cmux_embed::PackedStr::__new(bytes, text.len())
    }

    fn embedded() -> Bundle {
        Box::leak(Box::new([
            ("index.html", packed("<meta content=\"connect-src 'none'\">")),
            ("pane.js", packed("embedded")),
        ]))
    }

    #[tokio::test]
    async fn app_assets_lookup_order_is_override_then_adjacent_then_embedded() {
        let exe_dir = tempfile::tempdir().unwrap();
        let exe = exe_dir.path().join("bin/acpmux");
        let adjacent = exe_dir.path().join("bin/agent-pane");
        let configured = tempfile::tempdir().unwrap();
        for (dir, text) in [(&adjacent, "adjacent"), (configured.path(), "override")] {
            tokio::fs::create_dir_all(dir).await.unwrap();
            tokio::fs::write(dir.join("index.html"), text).await.unwrap();
            tokio::fs::write(dir.join("pane.js"), text).await.unwrap();
        }
        let get = |path: &'static str, configured: Option<PathBuf>| {
            let exe = exe.clone();
            async move { serve_from(path, &exe, configured, embedded()).await }
        };
        // The override wins over the adjacent directory and the bundle.
        let r = get("/app/pane.js", Some(configured.path().to_owned())).await;
        assert_eq!((r.0, r.1), ("200 OK", b"override".to_vec()));
        // Then the directory beside the binary.
        let r = get("/app/pane.js", None).await;
        assert_eq!((r.0, r.1), ("200 OK", b"adjacent".to_vec()));
        // Then the bundle, with nothing on disk.
        tokio::fs::remove_dir_all(&adjacent).await.unwrap();
        let r = get("/app/pane.js", None).await;
        assert_eq!((r.0, r.1), ("200 OK", b"embedded".to_vec()));
        // The same CSP rewrite as a file from disk.
        let (status, body, kind) = get("/app/", None).await;
        assert_eq!(status, "200 OK");
        assert_eq!(kind, "text/html; charset=utf-8");
        assert_eq!(body, b"<meta content=\"connect-src 'self'\">");
        // Not allowlisted, or allowlisted but not in the bundle: 404, never the 503.
        assert_eq!(get("/app/config.json", None).await.0, "404 Not Found");
        assert_eq!(get("/app/chunks/../pane.js", None).await.0, "404 Not Found");
        assert_eq!(get("/app/pane.css", None).await.0, "404 Not Found");
        // No bundle and nothing on disk: the old 503.
        let none = serve_from("/app/", &exe, None, &[]).await;
        assert_eq!(none.0, "503 Service Unavailable");
    }

    #[test]
    fn app_assets_paths_are_only_production_outputs() {
        for path in [
            "/app/",
            "/app/index.html",
            "/app/pane.js",
            "/app/pane.css",
            "/app/pane-copy.css",
            "/app/chunks/chunk-AB12.js",
            "/app/locales/zh-Hant.js",
            "/app/highlight-worker.js",
            "/app/image-worker.js",
            "/app/chat-snapshot.js",
            "/app/__snapshot/chat.js",
        ] {
            assert!(asset(path).is_some(), "{path}");
        }
        for path in [
            "/app",
            "/app/../config.json",
            "/app/%2e%2e/config.json",
            "/app/chunks/../../secret.js",
            "/app/chunks/%2e%2e.js",
            "/app/chunks/..\\secret.js",
            "/app/chunks/.hidden.js",
            "/app/pane.js.map",
            "/app/config.json",
            "/app/locales/",
            "/app//pane.js",
            "/app/chunks/a/b.js",
        ] {
            assert!(asset(path).is_none(), "{path}");
        }
    }

    #[tokio::test]
    async fn app_assets_preserve_bytes_and_only_change_browser_csp() {
        let dir = tempfile::tempdir().unwrap();
        let original = b"<meta content=\"script-src 'self'; connect-src 'none'\">";
        tokio::fs::write(dir.path().join("index.html"), original).await.unwrap();
        let (status, body, kind) = read(dir.path(), "index.html", "text/html").await;
        assert_eq!(status, "200 OK");
        assert_eq!(kind, "text/html");
        assert_eq!(body, b"<meta content=\"script-src 'self'; connect-src 'self'\">");
        assert_eq!(tokio::fs::read(dir.path().join("index.html")).await.unwrap(), original);
        let bytes = [0, 255, 128, 42];
        tokio::fs::write(dir.path().join("pane.js"), bytes).await.unwrap();
        assert_eq!(read(dir.path(), "pane.js", "text/javascript").await.1, bytes);
        assert_eq!(read(dir.path(), "missing.js", "text/javascript").await.0, "404 Not Found");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn app_assets_symlinks_cannot_escape_the_resource_root() {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let secret = outside.path().join("secret.js");
        tokio::fs::write(&secret, "private").await.unwrap();
        std::os::unix::fs::symlink(secret, dir.path().join("pane.js")).unwrap();
        assert_eq!(read(dir.path(), "pane.js", "text/javascript").await.0, "404 Not Found");
    }

    #[test]
    fn app_assets_use_only_explicit_or_adjacent_resources() {
        let exe = Path::new("/Applications/cmux.app/Contents/Resources/bin/acpmux");
        let candidates = roots(exe, None);
        assert!(candidates.contains(&PathBuf::from(
            "/Applications/cmux.app/Contents/Resources/CmuxNext_CmuxNextAgentPane.bundle/Contents/Resources/agent-pane"
        )));
        assert_eq!(
            roots(exe, Some("/packaged/pane".into())),
            vec![PathBuf::from("/packaged/pane")]
        );
    }
}
