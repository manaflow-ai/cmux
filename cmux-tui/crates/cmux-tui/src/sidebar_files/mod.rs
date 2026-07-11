mod files;
mod navigation;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

pub use files::FileEntry;
use files::{filtered_indices, list_directory};
use navigation::Navigation;

const REFRESH_EVERY: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum FileCommand {
    Cd(PathBuf),
    OpenEditor(PathBuf),
    OpenBrowser(PathBuf),
    Reroot,
}

pub struct FileBrowser {
    navigation: Navigation,
    fallback_cwd: PathBuf,
    entries: Vec<FileEntry>,
    visible: Vec<usize>,
    selected: usize,
    show_hidden: bool,
    filter_mode: bool,
    query: String,
    listing_error: Option<String>,
    message: Option<String>,
    last_refresh: Instant,
}

impl FileBrowser {
    pub fn new(fallback_cwd: PathBuf) -> Self {
        let mut browser = Self {
            navigation: Navigation::new(fallback_cwd.clone()),
            fallback_cwd,
            entries: Vec::new(),
            visible: Vec::new(),
            selected: 0,
            show_hidden: false,
            filter_mode: false,
            query: String::new(),
            listing_error: None,
            message: None,
            last_refresh: Instant::now(),
        };
        browser.reload_directory();
        browser
    }

    pub fn current_dir(&self) -> &Path {
        self.navigation.current_dir()
    }

    pub fn fallback_cwd(&self) -> &Path {
        &self.fallback_cwd
    }

    pub fn is_pinned(&self) -> bool {
        self.navigation.is_pinned()
    }

    pub fn visible_entries(&self) -> impl Iterator<Item = &FileEntry> {
        self.visible.iter().map(|index| &self.entries[*index])
    }

    pub fn total_len(&self) -> usize {
        self.entries.len()
    }

    pub fn selected(&self) -> usize {
        self.selected
    }

    pub fn show_hidden(&self) -> bool {
        self.show_hidden
    }

    pub fn filter_mode(&self) -> bool {
        self.filter_mode
    }

    pub fn query(&self) -> &str {
        &self.query
    }

    pub fn listing_error(&self) -> Option<&str> {
        self.listing_error.as_deref()
    }

    pub fn message(&self) -> Option<&str> {
        self.message.as_deref()
    }

    pub fn select(&mut self, index: usize) {
        if self.visible.is_empty() {
            self.selected = 0;
        } else {
            self.selected = index.min(self.visible.len() - 1);
        }
    }

    pub fn set_message(&mut self, message: impl Into<String>) {
        self.message = Some(message.into());
    }

    pub fn follow_focused_cwd(&mut self, directory: &Path) -> bool {
        if !self.navigation.follow_focused_cwd(directory) {
            return false;
        }
        self.query.clear();
        self.reload_directory();
        true
    }

    pub fn reroot(&mut self, directory: PathBuf) {
        self.navigation.reroot(directory);
        self.query.clear();
        self.reload_directory();
    }

    pub fn refresh(&mut self) {
        self.reload_directory();
    }

    pub fn refresh_due(&self, now: Instant) -> bool {
        now.duration_since(self.last_refresh) >= REFRESH_EVERY
    }

    pub fn tick(&mut self, now: Instant) -> bool {
        if !self.refresh_due(now) {
            return false;
        }
        self.reload_directory();
        true
    }

    pub fn handle_key(&mut self, key: &KeyEvent) -> Option<FileCommand> {
        self.message = None;
        if self.filter_mode {
            return self.handle_filter_key(key);
        }

        // Only plain (or shifted) character keys act; control/alt chords must
        // never fall through to actions (Ctrl-C reaching the 'c' arm would cd
        // the user's shell). ctrl+j/k are the explicit exceptions.
        let plain = key.modifiers.is_empty() || key.modifiers == KeyModifiers::SHIFT;
        match key.code {
            KeyCode::Up => self.move_selection(-1),
            KeyCode::Char('k') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.move_selection(-1);
            }
            KeyCode::Down => self.move_selection(1),
            KeyCode::Char('j') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.move_selection(1);
            }
            KeyCode::Right => self.descend_selected(),
            KeyCode::Enter => return self.activate_selected(),
            KeyCode::Left => self.go_parent(),
            KeyCode::Char('h') if plain => self.go_parent(),
            KeyCode::Char('.') if plain => {
                self.show_hidden = !self.show_hidden;
                self.reload_directory();
            }
            KeyCode::Char('/') if plain => self.filter_mode = true,
            KeyCode::Char('~') if plain => return Some(FileCommand::Reroot),
            KeyCode::Char('c') if plain => return self.cd_selected(),
            KeyCode::Char('o') if plain => return self.browser_selected(),
            _ => {}
        }
        None
    }

    pub fn insert_filter_text(&mut self, text: &str) -> bool {
        if !self.filter_mode || text.is_empty() {
            return false;
        }
        let keep = self.selected_entry().map(|entry| entry.path);
        self.query.extend(text.chars().filter(|ch| !ch.is_control()));
        self.apply_filter(keep.as_deref());
        true
    }

    fn handle_filter_key(&mut self, key: &KeyEvent) -> Option<FileCommand> {
        match key.code {
            KeyCode::Esc if !self.query.is_empty() => {
                let keep = self.selected_entry().map(|entry| entry.path);
                self.query.clear();
                self.apply_filter(keep.as_deref());
            }
            KeyCode::Esc => self.filter_mode = false,
            KeyCode::Enter => {
                self.filter_mode = false;
                return self.activate_selected();
            }
            KeyCode::Right => {
                self.filter_mode = false;
                self.descend_selected();
            }
            KeyCode::Backspace => {
                let keep = self.selected_entry().map(|entry| entry.path);
                self.query.pop();
                self.apply_filter(keep.as_deref());
            }
            KeyCode::Up => self.move_selection(-1),
            KeyCode::Down => self.move_selection(1),
            KeyCode::Char('k') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.move_selection(-1);
            }
            KeyCode::Char('j') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.move_selection(1);
            }
            KeyCode::Char(ch)
                if key.modifiers.is_empty() || key.modifiers == KeyModifiers::SHIFT =>
            {
                let keep = self.selected_entry().map(|entry| entry.path);
                self.query.push(ch);
                self.apply_filter(keep.as_deref());
            }
            _ => {}
        }
        None
    }

    fn move_selection(&mut self, delta: isize) {
        if self.visible.is_empty() {
            self.selected = 0;
        } else {
            self.selected = self.selected.saturating_add_signed(delta).min(self.visible.len() - 1);
        }
    }

    fn selected_entry(&self) -> Option<FileEntry> {
        self.visible.get(self.selected).map(|index| self.entries[*index].clone())
    }

    fn descend_selected(&mut self) {
        if let Some(entry) = self.selected_entry().filter(FileEntry::is_dir) {
            self.navigation.navigate(entry.path);
            self.query.clear();
            self.reload_directory();
        }
    }

    fn go_parent(&mut self) {
        if let Some(parent) = self.navigation.current_dir().parent() {
            self.navigation.navigate(parent.to_path_buf());
            self.query.clear();
            self.reload_directory();
        }
    }

    fn activate_selected(&mut self) -> Option<FileCommand> {
        let entry = self.selected_entry()?;
        if entry.is_dir() {
            self.navigation.navigate(entry.path);
            self.query.clear();
            self.reload_directory();
            return None;
        }
        Some(FileCommand::OpenEditor(entry.path))
    }

    fn cd_selected(&mut self) -> Option<FileCommand> {
        let Some(entry) = self.selected_entry().filter(FileEntry::is_dir) else {
            self.set_message("select a directory to send cd");
            return None;
        };
        Some(FileCommand::Cd(entry.path))
    }

    fn browser_selected(&mut self) -> Option<FileCommand> {
        let Some(entry) = self.selected_entry().filter(|entry| !entry.is_dir()) else {
            self.set_message("select an .html or .md file to open");
            return None;
        };
        let supported =
            entry.path.extension().and_then(|extension| extension.to_str()).is_some_and(
                |extension| {
                    extension.eq_ignore_ascii_case("html") || extension.eq_ignore_ascii_case("md")
                },
            );
        if !supported {
            self.set_message("only .html and .md files open in a browser");
            return None;
        }
        Some(FileCommand::OpenBrowser(entry.path))
    }

    fn reload_directory(&mut self) {
        let selected_path = self.selected_entry().map(|entry| entry.path);
        match list_directory(self.navigation.current_dir(), self.show_hidden) {
            Ok(entries) => {
                self.entries = entries;
                self.listing_error = None;
            }
            Err(error) => {
                self.entries.clear();
                self.listing_error = Some(error.to_string());
            }
        }
        self.last_refresh = Instant::now();
        self.apply_filter(selected_path.as_deref());
    }

    fn apply_filter(&mut self, selected_path: Option<&Path>) {
        self.visible = filtered_indices(&self.entries, &self.query);
        self.selected = selected_path
            .and_then(|path| {
                self.visible.iter().position(|index| self.entries[*index].path == path)
            })
            .unwrap_or_else(|| {
                if self.visible.is_empty() { 0 } else { self.selected.min(self.visible.len() - 1) }
            });
    }
}

pub fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn file_url(path: &Path) -> String {
    let text = path.to_string_lossy();
    let mut url = String::from("file://");
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                url.push(char::from(byte));
            }
            _ => url.push_str(&format!("%{byte:02X}")),
        }
    }
    url
}

#[cfg(test)]
mod tests {
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

    #[test]
    fn quotes_shell_paths_with_apostrophes() {
        assert_eq!(shell_single_quote("/tmp/a'b"), "'/tmp/a'\\''b'");
    }

    #[test]
    fn creates_percent_encoded_file_url() {
        assert_eq!(file_url(Path::new("/tmp/a file#1.md")), "file:///tmp/a%20file%231.md");
    }
}
