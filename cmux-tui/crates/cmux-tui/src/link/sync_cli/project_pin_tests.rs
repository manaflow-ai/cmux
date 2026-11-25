use super::*;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn a_path_is_taken_relative_to_the_projected_folder_from_either_side() {
    let mac = Path::new("/Users/me/repo");
    let remote = "/home/work/repo";
    let at = |path: &str| folder_path(Some(mac), remote, path).ok();
    assert_eq!(at("/Users/me/repo/src/deep").as_deref(), Some("src/deep"));
    assert_eq!(at("/home/work/repo/src").as_deref(), Some("src"));
    assert_eq!(at("src/./deep/").as_deref(), Some("src/deep"));
    assert_eq!(at(".").as_deref(), Some(""));
    assert_eq!(at("/Users/me/repo").as_deref(), Some(""));
    assert_eq!(at("/etc/passwd"), None, "outside both folders");
    assert_eq!(at("src/../../x"), None, "`..` is refused");
    // On the machine, by name: only its mount or a relative path.
    assert_eq!(folder_path(None, remote, "/home/work/repo/a").ok().as_deref(), Some("a"));
    assert!(folder_path(None, remote, "/Users/me/repo/a").is_err());
}

#[test]
fn the_flags_and_words_parse_and_a_wrong_shape_is_the_usage() {
    let parsed = parse(&words("--socket /s --at /r --name chat-1 src")).ok();
    let expected = PinArgs {
        socket: Some(PathBuf::from("/s")),
        at: Some("/r".into()),
        name: Some("chat-1".into()),
        words: vec!["src".into()],
    };
    assert_eq!(parsed, Some(expected));
    assert!(parse(&words("--bogus")).is_err());
    assert!(parse(&words("--name")).is_err());
    let refused = |line: &str| command("pin", &words(line)).err().map(|error| error.to_string());
    assert_eq!(refused("--at /r --name n src").as_deref(), Some("--socket is required"));
    assert_eq!(refused("--socket /s --name n src").as_deref(), Some("--at is required"));
    assert_eq!(refused("--socket /s --at /r --name n").as_deref(), Some(usage()));
    let pins = command("pins", &words("--socket /s --at /r --name n src")).err();
    assert_eq!(pins.map(|error| error.to_string()).as_deref(), Some(usage()));
}

#[test]
fn a_machine_that_cannot_be_reached_is_an_error_not_an_answer() {
    let missing = std::env::temp_dir().join(format!("cmux-pin-test-{}.sock", std::process::id()));
    let line = format!("--socket {} --at /r --name n src", missing.display());
    let error = command("pin", &words(&line)).err().map(|error| format!("{error:#}"));
    assert!(error.is_some_and(|error| error.contains("cannot reach the machine")));
}
