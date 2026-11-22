use super::*;

#[test]
fn w5q_options_read_the_last_numbered_run_and_its_cursor() {
    let screen = " Pick one\n 1. not this list\n 2. either\n\n ❯ 1. Yes, proceed\n   2. No, exit\n\n Enter to confirm";
    let read = options(screen);
    assert_eq!(
        read,
        [
            DialogOption { number: 1, label: "Yes, proceed".into(), selected: true },
            DialogOption { number: 2, label: "No, exit".into(), selected: false },
        ]
    );
    assert_eq!(accept_keys(&read), Some(vec!["enter"]));
    assert!(options("⏺ 1. a numbered line alone").is_empty());
    let none_yes = options(" ❯ 1. No, exit\n   2. Maybe");
    assert_eq!(accept_keys(&none_yes), None);
    let below = options(" ❯ 1. No, exit\n   2. Later\n   3. Yes, I trust this folder");
    assert_eq!(accept_keys(&below), Some(vec!["down", "down", "enter"]));
}

/// W5-Q review (PR C): the person approves the exact text the keys
/// pick, so the result names it (`accept_label`).
#[test]
fn w5q_the_accept_label_is_the_option_the_keys_pick() {
    let below = options(" ❯ 1. No, exit\n   2. Later\n   3. Yes, I trust this folder");
    assert_eq!(accept_label(&below), Some("Yes, I trust this folder"));
    assert_eq!(accept_label(&options(" ❯ 1. No, exit\n   2. Maybe")), None);
}

/// W5-Q review 3 (PR C): a dialog drawn in a box ends each row with
/// `│`; the label the person approves has no box character.
#[test]
fn w5q_a_boxed_option_label_has_no_box_character() {
    let boxed =
        options("│ ❯ 1. Yes, I trust this folder      │\n│   2. No, exit                     │");
    assert_eq!(accept_label(&boxed), Some("Yes, I trust this folder"));
    assert_eq!(boxed.get(1).map(|option| option.label.as_str()), Some("No, exit"));
}

/// W5-Q review (PR C): the folder-trust reason is localized, names the
/// terminal (never the placeholder `NAME`), names the option the keys
/// pick, and warns when that option also turns approvals off (a Codex
/// "... without asking for approval" choice).
#[test]
fn w5q_the_folder_trust_reason_names_the_choice_and_warns_on_no_approval() {
    let english = &crate::localization::catalog_for_locale("en_US.UTF-8").pane_cli;
    let japanese = &crate::localization::catalog_for_locale("ja_JP.UTF-8").pane_cli;
    let plain = "Yes, I trust this folder";
    let risky = "Yes, allow Codex to work in this folder without asking for approval";
    let keys: &[&str] = &["up", "enter"];
    for messages in [english, japanese] {
        let asked = folder_trust_reason(messages, "beta", None);
        assert!(!asked.contains("NAME"), "{asked}");
        assert!(asked.contains("cmux terminal beta keys"), "{asked}");
        let named = folder_trust_reason(messages, "beta", Some((keys, plain)));
        assert!(named.contains("cmux terminal beta keys up enter"), "{named}");
        assert!(named.contains(plain), "{named}");
    }
    let en = folder_trust_reason(english, "beta", Some((keys, plain)));
    let ja = folder_trust_reason(japanese, "beta", Some((keys, plain)));
    assert_ne!(en, ja, "the Japanese reason is Japanese");
    assert!(!en.contains("warning:"), "{en}");
    let warned = folder_trust_reason(english, "beta", Some((keys, risky)));
    assert!(warned.contains("warning:"), "{warned}");
    let warned = folder_trust_reason(japanese, "beta", Some((keys, risky)));
    assert!(warned.contains("警告"), "{warned}");
    assert!(!warned.contains("; "), "the Japanese reason has an ASCII separator: {warned}");
}
