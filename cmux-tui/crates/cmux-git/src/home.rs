//! The home folder's repository. A person may keep the home folder itself in git (a dotfiles
//! repository, `~/.git`). Then every folder under the home folder that has no repository of its
//! own is in that one: git names the home folder as its top level, and every file of the home
//! folder that the repository does not track is one of its untracked files. A listing of them
//! (`git status` with untracked files, `ls-files --others`) reads every folder of the home folder:
//! Pictures and the Photos library, Desktop, Documents, the Trash. On macOS each of those reads
//! raises a privacy prompt that names cmux, on a screen that may have nobody at it
//! (LAUNCH-NO-TCC-PROMPTS), and the walk costs as much as the person has files.
//!
//! So a read of such a repository lists its tracked files only: its branch and its refs read as
//! for any repository, and no run lists what it does not track. Other tools make the same call:
//! powerlevel10k's default `POWERLEVEL9K_VCS_DISABLED_WORKDIR_PATTERN='~'` shows no status for
//! `$HOME/.git`, VS Code opens no repository it finds in a parent folder unless asked
//! (`git.openRepositoryInParentFolders`), and the dotfiles recipes set
//! `status.showUntrackedFiles=no` in such a repository.

use std::path::{Path, PathBuf};

/// Whether `path` is the person's home folder, as spelled or with its symlinks resolved. `false`
/// when the process names no home folder.
pub fn is_home_folder(path: &Path) -> bool {
    home_folder().is_some_and(|home| is_home_folder_of(path, &home))
}

/// Whether `path` is the home folder `home`, as spelled or with its symlinks resolved.
pub fn is_home_folder_of(path: &Path, home: &Path) -> bool {
    if path == home {
        return true;
    }
    // git names a top level with its symlinks resolved; the home folder can be reached through
    // one (`/var` on macOS, `/home` on some systems).
    match (std::fs::canonicalize(path), std::fs::canonicalize(home)) {
        (Ok(path), Ok(home)) => path == home,
        _ => false,
    }
}

/// The home folder the process runs for: `HOME`, as git reads it.
fn home_folder() -> Option<PathBuf> {
    #[cfg(unix)]
    let variable = "HOME";
    #[cfg(not(unix))]
    let variable = "USERPROFILE";
    std::env::var_os(variable).filter(|home| !home.is_empty()).map(PathBuf::from)
}
