use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_string()).collect()
}

#[test]
fn tui_words_parse_to_install_path_or_run() {
    assert_eq!(
        parse(&words(&["install", "--force"])),
        Ok(TuiCommand::Install { manifest_url: DEFAULT_MANIFEST_URL.to_string(), force: true })
    );
    assert_eq!(
        parse(&words(&["install", "--manifest-url", "https://example.test/x/manifest.json"])),
        Ok(TuiCommand::Install {
            manifest_url: "https://example.test/x/manifest.json".to_string(),
            force: false
        })
    );
    assert!(parse(&words(&["install", "--manifest-url", "http://example.test/m.json"])).is_err());
    assert!(parse(&words(&["install", "--bogus"])).is_err());
    assert_eq!(parse(&words(&["path"])), Ok(TuiCommand::Path));
    assert_eq!(parse(&words(&[])), Ok(TuiCommand::Run(Vec::new())));
    assert_eq!(
        parse(&words(&["--session", "work"])),
        Ok(TuiCommand::Run(words(&["--session", "work"])))
    );
}

#[test]
fn every_published_platform_has_a_manifest_key() {
    assert_eq!(
        manifest_binary_key("macos", "aarch64").as_deref(),
        Some("cmux-tui-aarch64-apple-darwin")
    );
    assert_eq!(
        manifest_binary_key("macos", "x86_64").as_deref(),
        Some("cmux-tui-x86_64-apple-darwin")
    );
    assert_eq!(
        manifest_binary_key("linux", "x86_64").as_deref(),
        Some("cmux-tui-x86_64-unknown-linux-musl")
    );
    assert_eq!(
        manifest_binary_key("linux", "aarch64").as_deref(),
        Some("cmux-tui-aarch64-unknown-linux-musl")
    );
    assert_eq!(
        manifest_binary_key("windows", "x86_64").as_deref(),
        Some("cmux-tui-x86_64-pc-windows-gnu.exe")
    );
    assert_eq!(manifest_binary_key("freebsd", "x86_64"), None);
}

#[test]
fn a_manifest_entry_sits_beside_the_manifest_and_needs_a_sha256() {
    let sha = "ab".repeat(32);
    let manifest = serde_json::json!({
        "commit": "c0ffee",
        "binaries": {"cmux-tui-x86_64-unknown-linux-musl": sha, "cmux-tui-bad": "xyz"},
    });
    let entry = manifest_entry(
        "https://files.cmux.com/cmux-tui/latest/manifest.json?v=1",
        &manifest,
        "cmux-tui-x86_64-unknown-linux-musl",
    )
    .unwrap();
    assert_eq!(
        entry.url,
        "https://files.cmux.com/cmux-tui/latest/cmux-tui-x86_64-unknown-linux-musl"
    );
    assert_eq!(entry.sha256, sha);
    assert_eq!(entry.commit.as_deref(), Some("c0ffee"));
    assert!(manifest_entry("https://h/m.json", &manifest, "cmux-tui-bad").is_err());
    assert!(manifest_entry("https://h/m.json", &manifest, "cmux-tui-missing").is_err());
}

#[test]
fn sha256_hex_is_lowercase_hex() {
    assert_eq!(
        sha256_hex(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}
