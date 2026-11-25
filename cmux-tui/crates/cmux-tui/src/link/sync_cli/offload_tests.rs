use std::path::Path;

use super::{default_at, parse, shell_line};

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parse_takes_the_options_before_the_dash_dash_and_the_command_after() {
    let args = parse(&words("--socket /s --at /home/u/v --cwd /p --keep -- cargo build --release"))
        .unwrap();
    assert_eq!(args.socket, Path::new("/s"));
    assert_eq!(args.at.as_deref(), Some("/home/u/v"));
    assert_eq!(args.folder.as_deref(), Some(Path::new("/p")));
    assert!(args.keep);
    assert_eq!(args.argv, words("cargo build --release"));
}

#[test]
fn parse_refuses_a_missing_socket_command_or_relative_mount() {
    assert!(parse(&words("--at /x -- make")).is_err());
    assert!(parse(&words("--socket /s --")).is_err());
    assert!(parse(&words("--socket /s make")).is_err());
    assert!(parse(&words("--socket /s --at rel -- make")).is_err());
    assert!(parse(&words("--socket /s --bogus -- make")).is_err());
}

#[test]
fn shell_line_quotes_only_what_a_shell_would_split_or_expand() {
    let argv: Vec<String> =
        ["cargo", "test", "-p", "a_b", "it's here", "$HOME", ""].map(str::to_owned).to_vec();
    assert_eq!(shell_line(&argv), r#"cargo test -p a_b 'it'\''s here' '$HOME' ''"#);
}

#[test]
fn default_at_is_one_plain_folder_per_offload_under_the_machine_home() {
    let at = default_at("/home/u/", Path::new("/Users/l/My App!"), "offload-00ff");
    assert_eq!(at, "/home/u/.cmux/offload/My_App_-00ff");
    assert_eq!(default_at("/root", Path::new("/"), "offload-1"), "/root/.cmux/offload/folder-1");
}
