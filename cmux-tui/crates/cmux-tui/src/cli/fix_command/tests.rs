use super::*;

#[test]
fn the_daemon_cli_fix_quotes_only_what_needs_it() {
    let text = run_with_daemon_cli(
        Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux"),
        ["--socket", "/tmp/a b.sock", "tab", "list", "it's"],
    );
    assert_eq!(
        text,
        "'/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux' --socket '/tmp/a b.sock' tab list 'it'\\''s'"
    );
}
