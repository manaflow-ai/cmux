use super::*;

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
    assert_eq!(roots(exe, Some("/packaged/pane".into())), vec![PathBuf::from("/packaged/pane")]);
}
