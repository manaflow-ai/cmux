use super::*;

fn home(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-reserved-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

#[test]
fn a_reserved_folder_is_private_named_by_its_ticket_and_kept_until_taken() {
    let home = home("ensure");
    let first = ensure_folder(&home).expect("a folder");
    let name = first.file_name().unwrap().to_str().unwrap().to_owned();
    assert!(is_reserved_name(&name), "{name}");
    assert!(!name.bytes().all(|b| b.is_ascii_digit()), "never a surface id");
    assert!(private_dir(&home.join("chats")) && private_dir(&first));
    assert_eq!(std::fs::read_to_string(home.join("chats/.reserved")).unwrap(), name);
    // Asked again before a chat took it: the same folder, no second one.
    assert_eq!(ensure_folder(&home), Some(first.clone()));
    // A chat took the ticket: the next ask makes a new folder.
    std::fs::rename(home.join("chats/.reserved"), home.join("chats/.claimed-7")).unwrap();
    let second = ensure_folder(&home).expect("a new folder");
    assert_ne!(second, first);
    assert!(first.is_dir(), "the taken folder is the chat's");
    let _ = std::fs::remove_dir_all(home);
}

#[cfg(unix)]
#[test]
fn a_link_in_place_of_the_chats_folder_is_never_followed() {
    let home = home("link");
    let elsewhere = home.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    std::os::unix::fs::symlink(&elsewhere, home.join("chats")).unwrap();
    assert_eq!(ensure_folder(&home), None);
    assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0);
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn shapes_are_a_short_list_of_harness_ids_with_optional_models() {
    assert_eq!(parse_shapes(None).unwrap(), vec![]);
    let v = json!([
        {"harness": "codex", "model": "gpt-5.5"},
        {"harness": "claude", "preset": "work", "model": "claude-opus-5-5[1m]"},
        {"harness": "codex", "model": "gpt-5.5"}
    ]);
    let got = parse_shapes(Some(&v)).unwrap();
    assert_eq!(got.len(), 2, "a repeated shape counts once");
    assert_eq!(got[1].preset.as_deref(), Some("work"));
    assert_eq!(got[1].model.as_deref(), Some("claude-opus-5-5[1m]"));
    for bad in [
        json!({"harness": "codex"}),
        json!([{"model": "x"}]),
        json!([{"harness": "../codex"}]),
        json!([{"harness": "codex", "model": "a\nb"}]),
        json!([{"harness": "a"}, {"harness": "b"}, {"harness": "c"}, {"harness": "d"}, {"harness": "e"}]),
    ] {
        assert!(parse_shapes(Some(&bad)).is_err(), "{bad}");
    }
}

#[test]
fn only_a_reserved_folder_in_home_chats_is_a_home_chat_folder() {
    let home = Path::new("/home/p");
    let name = "r0123456789abcdef0123456789abcdef";
    assert!(is_home_chat_folder(home, &home.join("chats").join(name)));
    assert!(!is_home_chat_folder(home, &home.join("chats/12345")), "a surface id folder");
    assert!(!is_home_chat_folder(home, &home.join("src").join(name)));
}
