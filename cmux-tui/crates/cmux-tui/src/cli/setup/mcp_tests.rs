use super::redact_url_credentials as redact;

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|a| (*a).to_owned()).collect()
}

/// Secret-shaped values are redacted; a plain command line stays as it is.
#[test]
fn secret_shaped_args_are_redacted() {
    let r = |args: &[&str]| super::redact_secrets(&strings(args));
    assert_eq!(r(&["--token=abc", "x"]), ["--token=<redacted>", "x"]);
    assert_eq!(r(&["--api-key", "abc", "mcp"]), ["--api-key", "<redacted>", "mcp"]);
    assert_eq!(r(&["--password=hunter2"]), ["--password=<redacted>"]);
    assert_eq!(
        r(&["KEY=sk9f8a7d6s5f4g3h2j1k0l", "https://u:p@h/x"]),
        ["KEY=<redacted>", "https://<redacted>@h/x"]
    );
    assert_eq!(
        r(&["--header", "Authorization: Bearer abc.def", "-H", "X-Api-Key: k1"]),
        ["--header", "Authorization: <redacted>", "-H", "X-Api-Key: <redacted>"]
    );
    assert_eq!(
        r(&["--header=Authorization: Basic dXNlcjpw"]),
        ["--header=Authorization: <redacted>"]
    );
    assert_eq!(r(&["X-Custom: Token t0k3n"]), ["X-Custom: <redacted>"]);
    assert_eq!(r(&["mcp", "ghp1a2b3c4d5e6f7g8h9i0j1k2l3m4n"]), ["mcp", "<redacted>"]);
    assert_eq!(
        r(&["eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"]),
        ["<redacted>"]
    );
    assert_eq!(
        r(&["--url=https://h.example/mcp?access_token=abc&v=2", "https://h/x?api_key=k#top"]),
        [
            "--url=https://h.example/mcp?access_token=<redacted>&v=2",
            "https://h/x?api_key=<redacted>#top"
        ]
    );
    assert_eq!(
        r(&["-H", "Authorization:", "Bearer xyz", "mcp"]),
        ["-H", "Authorization: <redacted>", "<redacted>", "mcp"]
    );
    assert_eq!(
        r(&["-H", "Authorization: Bearer", "xyz"]),
        ["-H", "Authorization: <redacted>", "<redacted>"]
    );
    assert_eq!(r(&["Bearer", "xyz", "mcp"]), ["Bearer", "<redacted>", "mcp"]);
    assert_eq!(
        r(&["--header=Authorization: Bearer", "xyz", "mcp"]),
        ["--header=Authorization: <redacted>", "<redacted>", "mcp"]
    );
    assert_eq!(
        r(&["--header=Authorization:", "Bearer xyz"]),
        ["--header=Authorization: <redacted>", "<redacted>"]
    );
    for plain in [
        &["npx", "-y", "cmux", "mcp", "serve"][..],
        &["/Applications/cmux.app/Contents/Resources/bin/cmux", "mcp", "serve", "--all-tools"],
        &["--registry=https://npm.example/", "--keep-alive", "LANG=en_US.UTF-8"],
        &["MODE=aaaaaaaaaaaaaaaaaaaaaaaaa"],
        &["lib/node_modules/cmux-tui-linux-x64/bin/cmux-tui", "mcp", "serve"],
        &["cmux@1.2.3-beta.4", "Content-Type: application/json", "abcdefghijklmnopqrstuvwxyzab"],
        &["https://npm.example/cmux?v=2&tag=next", "node_modules.cache.dir", "a.b.c"],
    ] {
        assert_eq!(r(plain), strings(plain), "{plain:?}");
    }
}

#[test]
fn url_credentials_are_redacted_and_nothing_else_changes() {
    assert_eq!(
        redact("--registry=https://me:tok@npm.example/x"),
        "--registry=https://<redacted>@npm.example/x"
    );
    assert_eq!(redact("https://tok@h"), "https://<redacted>@h");
    assert_eq!(
        redact("a http://u:p@h/ b https://v@w"),
        "a http://<redacted>@h/ b https://<redacted>@w"
    );
    for plain in ["https://npm.example/x", "mcp", "user@host", "https://h/a@b", ""] {
        assert_eq!(redact(plain), plain);
    }
}
