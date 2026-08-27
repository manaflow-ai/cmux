use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Navigation {
    current_dir: PathBuf,
    pinned: bool,
}

impl Navigation {
    pub fn new(current_dir: PathBuf) -> Self {
        Self { current_dir, pinned: false }
    }

    pub fn current_dir(&self) -> &Path {
        &self.current_dir
    }

    pub fn is_pinned(&self) -> bool {
        self.pinned
    }

    pub fn navigate(&mut self, directory: PathBuf) -> bool {
        let changed = self.current_dir != directory;
        self.current_dir = directory;
        self.pinned = true;
        changed
    }

    pub fn follow_focused_cwd(&mut self, directory: &Path) -> bool {
        if self.pinned || self.current_dir == directory {
            return false;
        }
        self.current_dir = directory.to_path_buf();
        true
    }

    pub fn reroot(&mut self, directory: PathBuf) -> bool {
        let changed = self.current_dir != directory;
        self.current_dir = directory;
        self.pinned = false;
        changed
    }
}

#[cfg(test)]
mod tests {
    use std::fs::{self, create_dir};

    use super::*;

    #[test]
    fn follows_until_navigation_pins_then_reroot_unpins() {
        let temp = std::env::temp_dir().join(format!(
            "cmux-tui-sidebar-navigation-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&temp);
        fs::create_dir_all(&temp).unwrap();
        let first = temp.join("first");
        let second = temp.join("second");
        let manual = temp.join("manual");
        create_dir(&first).unwrap();
        create_dir(&second).unwrap();
        create_dir(&manual).unwrap();

        let mut navigation = Navigation::new(first.clone());
        assert!(navigation.follow_focused_cwd(&second));
        assert_eq!(navigation.current_dir(), second);

        assert!(navigation.navigate(manual.clone()));
        assert!(navigation.is_pinned());
        assert!(!navigation.follow_focused_cwd(&first));
        assert_eq!(navigation.current_dir(), manual);

        assert!(navigation.reroot(first.clone()));
        assert!(!navigation.is_pinned());
        assert_eq!(navigation.current_dir(), first);
        assert!(navigation.follow_focused_cwd(&second));
        fs::remove_dir_all(temp).unwrap();
    }
}
