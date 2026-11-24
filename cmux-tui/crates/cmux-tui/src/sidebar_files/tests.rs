use std::fs::{self, create_dir, write};

use crossterm::event::{KeyEvent, KeyModifiers};

use super::*;

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::NONE)
}

#[test]
fn control_chords_never_trigger_character_actions() {
    // Regression: Ctrl-C fell through to the 'c' arm and cd'd the shell.
    let dir = temp_dir("ctrl-chords");
    create_dir(dir.join("sub")).unwrap();
    let mut browser = FileBrowser::new(dir.clone());
    browser.reload_directory();
    for ch in ['c', 'o', 'h', '.', '/', '~'] {
        let ev = KeyEvent::new(KeyCode::Char(ch), KeyModifiers::CONTROL);
        assert!(browser.handle_key(&ev).is_none(), "ctrl+{ch} must be inert");
    }
    assert!(!browser.filter_mode, "ctrl+/ must not enter filter mode");
    fs::remove_dir_all(&dir).ok();
}

fn temp_dir(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "cmux-tui-file-browser-{name}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn filter_edits_keep_selection_identity_and_escape_clears_before_exiting() {
    let temp = temp_dir("filter");
    write(temp.join("alpha"), "").unwrap();
    write(temp.join("beta"), "").unwrap();
    write(temp.join("gamma"), "").unwrap();
    let mut browser = FileBrowser::new(temp.clone());
    browser.select(1);

    browser.handle_key(&key(KeyCode::Char('/')));
    browser.handle_key(&key(KeyCode::Char('e')));
    assert!(browser.filter_mode());
    assert_eq!(browser.visible_entries().count(), 1);
    assert_eq!(browser.visible_entries().next().unwrap().name, "beta");

    browser.handle_key(&key(KeyCode::Esc));
    assert!(browser.filter_mode());
    assert_eq!(browser.query(), "");
    assert_eq!(browser.visible_entries().nth(browser.selected()).unwrap().name, "beta");

    browser.handle_key(&key(KeyCode::Esc));
    assert!(!browser.filter_mode());
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn filter_option_backspace_deletes_the_previous_word() {
    let temp = temp_dir("filter-option-backspace");
    let mut browser = FileBrowser::new(temp.clone());
    browser.handle_key(&key(KeyCode::Char('/')));
    assert!(browser.insert_filter_text("alpha beta"));

    browser.handle_key(&KeyEvent::new(KeyCode::Backspace, KeyModifiers::ALT));

    assert_eq!(browser.query(), "alpha ");
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn filter_backspace_deletes_one_extended_grapheme() {
    let temp = temp_dir("filter-grapheme-backspace");
    let mut browser = FileBrowser::new(temp.clone());
    browser.handle_key(&key(KeyCode::Char('/')));
    assert!(browser.insert_filter_text("á👨‍👩‍👧‍👦"));

    browser.handle_key(&key(KeyCode::Backspace));

    assert_eq!(browser.query(), "á");
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn enter_and_right_act_on_the_filtered_selection() {
    let temp = temp_dir("activate");
    create_dir(temp.join("docs")).unwrap();
    write(temp.join("notes.md"), "").unwrap();
    let mut browser = FileBrowser::new(temp.clone());

    browser.handle_key(&key(KeyCode::Char('/')));
    for ch in "notes".chars() {
        browser.handle_key(&key(KeyCode::Char(ch)));
    }
    assert_eq!(
        browser.handle_key(&key(KeyCode::Enter)),
        Some(FileCommand::OpenEditor(temp.join("notes.md")))
    );

    let mut browser = FileBrowser::new(temp.clone());
    browser.handle_key(&key(KeyCode::Char('/')));
    for ch in "docs".chars() {
        browser.handle_key(&key(KeyCode::Char(ch)));
    }
    browser.handle_key(&key(KeyCode::Right));
    assert_eq!(browser.current_dir(), temp.join("docs"));
    assert!(!browser.filter_mode());
    fs::remove_dir_all(temp).unwrap();
}

/// A directory name is attacker-chosen (a cloned repository). Its bytes
/// are typed into a line editor, which acts on control characters even
/// inside quotes: Ctrl-U erases the typed `cd '` and leaves the rest of
/// the name to run as a command. Such a path is never typed.
#[test]
fn cd_is_never_typed_for_a_path_with_control_characters() {
    assert_eq!(cd_command("/tmp/a'b").as_deref(), Some("cd '/tmp/a'\\''b'\n"));
    for evil in [
        "/tmp/x\u{15}touch /tmp/pwn #",
        "/tmp/a\nb",
        "/tmp/a\u{1b}[2~b",
        "/tmp/a\u{7f}b",
        "/tmp/a\u{9b}b",
    ] {
        assert_eq!(cd_command(evil), None, "{evil:?}");
    }
}

#[test]
fn quotes_shell_paths_with_apostrophes() {
    assert_eq!(shell_single_quote("/tmp/a'b"), "'/tmp/a'\\''b'");
}

#[test]
fn creates_percent_encoded_file_url() {
    assert_eq!(file_url(Path::new("/tmp/a file#1.md")), "file:///tmp/a%20file%231.md");
}

#[cfg(windows)]
#[test]
fn creates_windows_drive_file_url() {
    assert_eq!(file_url(Path::new(r"C:\a\b")), "file:///C:/a/b");
}
