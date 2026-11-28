use super::*;

const BASE: &str = "http://127.0.0.1:47380";

#[test]
fn rewrites_release_assets_and_archives_only() {
    let asset = "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex.tar.gz";
    assert_eq!(
        rewrite(asset, BASE).unwrap(),
        "http://127.0.0.1:47380/github.com/openai/codex/releases/download/rust-v0.156.1/codex.tar.gz"
    );
    assert!(rewrite("https://codeload.github.com/oven-sh/bun/tar.gz/bun-v1.2.0", BASE).is_some());
    assert!(rewrite("https://github.com/oven-sh/bun/archive/refs/tags/v1.tar.gz", BASE).is_some());
    for no in [
        "http://github.com/a/b/releases/download/t/f",
        "https://github.com/a/b/releases/download/t",
        "https://github.com/a/b/releases/download/t/f/g",
        "https://github.com/a/b/releases/latest/download/f",
        "https://github.com/a/b.git/info/refs",
        "https://github.com/a/b/releases/download/t/f?x=1",
        "https://github.com/a/../releases/download/t/f",
        "https://api.github.com/repos/a/b/releases/assets/1",
        "https://codeload.github.com/a/b/raw/main",
        "https://example.com/a/b/releases/download/t/f",
    ] {
        assert!(rewrite(no, BASE).is_none(), "{no}");
    }
}

#[test]
fn base_file_must_name_a_loopback_port() {
    let dir = std::env::temp_dir().join(format!("cmux-transport-rewrite-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("base");
    std::fs::write(&file, "http://127.0.0.1:47380\n").unwrap();
    assert_eq!(read_base(&file).as_deref(), Some(BASE));
    std::fs::write(&file, "http://evil.example:80\n").unwrap();
    assert_eq!(read_base(&file), None);
    std::fs::remove_file(&file).unwrap();
    assert_eq!(read_base(&file), None);
    std::fs::remove_dir(&dir).unwrap();
}
