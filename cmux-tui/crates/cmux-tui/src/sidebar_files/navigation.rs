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
