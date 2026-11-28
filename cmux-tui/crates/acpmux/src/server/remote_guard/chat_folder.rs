//! Part of `remote_guard.rs`: whether `~/chats` and a chat's folder there are safe to start a
//! Cloud chat in (`cloud_chat_folder_under`), why not in words that name the fault, and the one
//! fault acpmux repairs itself: its own folder left writable by its group or others.
//!
//! On 2026-11-28 fs-agent-lane-33's `~/chats` was mode 775 and every start with no folder was
//! refused as "/home/cmux/chats is not a directory", which read as a missing folder.

/// The `data.reason` of a start refused because the host's chat folder cannot be used: the
/// host's fault, not the caller's, so a placed start's machine passes the host over
/// (`placement::reach::refused_start`).
pub(crate) const CHAT_FOLDER_REASON: &str = "remote.chat_folder_unusable";

/// Why `~/chats` or a chat's folder there is not one acpmux starts a chat in.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ChatFolderFault {
    /// A symlink, even to a folder: the chat would start wherever it points.
    Symlink,
    /// A file or anything else that is not a folder.
    NotADirectory,
    /// A folder another user owns (its uid).
    NotOwned(u32),
    /// This user's folder that its group or anyone may write (its mode).
    Writable(u32),
}

impl ChatFolderFault {
    /// The refusal's text. Until 2026-11-28 every fault read "is not a directory", so a
    /// group-writable `~/chats` (mode 775, fs-agent-lane-33) read as a missing folder.
    pub(crate) fn describe(&self, path: &std::path::Path) -> String {
        let path = path.display();
        match self {
            Self::Symlink => format!("{path} is a symlink, not a directory"),
            Self::NotADirectory => format!("{path} is not a directory"),
            Self::NotOwned(uid) => format!("{path} is owned by uid {uid}, not this user"),
            Self::Writable(mode) => format!(
                "{path} is writable by its group or others (mode {:o}) and could not be made private",
                mode & 0o7777
            ),
        }
    }
}

/// [`ChatFolderFault`] of a path's own metadata (`symlink_metadata`), or `None` for a folder
/// this user owns that only it may write.
pub(crate) fn chat_folder_fault(metadata: &std::fs::Metadata) -> Option<ChatFolderFault> {
    if metadata.file_type().is_symlink() {
        return Some(ChatFolderFault::Symlink);
    }
    if !metadata.is_dir() {
        return Some(ChatFolderFault::NotADirectory);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        let uid = metadata.uid();
        if uid != unsafe { libc::geteuid() } {
            return Some(ChatFolderFault::NotOwned(uid));
        }
        if metadata.mode() & 0o022 != 0 {
            return Some(ChatFolderFault::Writable(metadata.mode()));
        }
    }
    None
}

/// A folder this user owns that its group or others may write, made private (`go-w`) in place:
/// whether it is safe now. Only this user's own real folder is changed (re-read without
/// following a link), never a symlink or another user's.
pub(super) fn repair_writable(path: &std::path::Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
        let Ok(metadata) = std::fs::symlink_metadata(path) else { return false };
        if !matches!(chat_folder_fault(&metadata), Some(ChatFolderFault::Writable(_))) {
            return false;
        }
        let mode = metadata.mode() & 0o7777 & !0o022;
        if std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).is_err() {
            return false;
        }
        let repaired =
            std::fs::symlink_metadata(path).is_ok_and(|m| chat_folder_fault(&m).is_none());
        if repaired {
            tracing::warn!(path = %path.display(), "chat folder was group or other writable; made private");
        }
        repaired
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}
