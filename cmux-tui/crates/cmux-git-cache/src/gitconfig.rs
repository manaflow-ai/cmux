//! The include the proxy writes while it listens. The machine's managed git config includes
//! this path; git ignores an include whose file is missing, so a machine whose proxy is not
//! running (never started, stopped, disabled) reaches GitHub directly, as before.

use std::io::Write;
use std::path::Path;

pub const DEFAULT_PORT: u16 = 47_380;
/// Where a Cloud machine's proxy writes its include (tmpfs: gone after a reboot).
pub const RUN_INCLUDE: &str = "/run/cmux/git-cache/gitconfig";
pub const HEADER: &str = "# cmux git cache (managed, do not edit): written while the proxy listens, removed when it stops.";

/// `git config` text: fetches of github.com (https and both ssh spellings) go to the proxy;
/// pushes stay on their own URL (`pushInsteadOf` wins over `insteadOf` for a push); the
/// proxy's credential prompt maps back to github.com's helpers through `helper`.
pub fn include_text(port: u16, helper: &str) -> String {
    let proxy = format!("http://127.0.0.1:{port}");
    let mut text = format!("{HEADER}\n[url \"{proxy}/github.com/\"]\n");
    for from in ["https://github.com/", "git@github.com:", "ssh://git@github.com/"] {
        text.push_str(&format!("\tinsteadOf = {from}\n"));
    }
    for from in ["https://github.com/", "git@github.com:", "ssh://git@github.com/"] {
        text.push_str(&format!("[url \"{from}\"]\n\tpushInsteadOf = {from}\n"));
    }
    text.push_str(&format!(
        "[credential \"{proxy}\"]\n\thelper = {helper}\n\tuseHttpPath = true\n"
    ));
    text
}

/// Atomic write (a part file, then rename), readable by every user.
pub fn write_include(path: &Path, text: &str) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let part = path.with_extension("part");
    {
        let mut f = std::fs::File::create(&part)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o644))?;
    }
    std::fs::rename(&part, path)
}

/// Removes the include if it is ours (its header), so git goes direct again.
pub fn remove_include(path: &Path) {
    if std::fs::read_to_string(path).is_ok_and(|t| t.starts_with(HEADER)) {
        let _ = std::fs::remove_file(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_rewrites_fetch_not_push() {
        let t = include_text(1234, "!/opt/cmux/current/bin/cmux host git-cache credential");
        assert!(t.starts_with(HEADER));
        assert!(t.contains(
            "[url \"http://127.0.0.1:1234/github.com/\"]\n\tinsteadOf = https://github.com/\n"
        ));
        assert!(t.contains("\tinsteadOf = git@github.com:\n"));
        assert!(t.contains("[url \"git@github.com:\"]\n\tpushInsteadOf = git@github.com:\n"));
        assert!(t.contains("[credential \"http://127.0.0.1:1234\"]\n\thelper = !/opt/cmux"));
    }

    #[test]
    fn remove_only_ours() {
        let dir = tempfile::tempdir().unwrap();
        let ours = dir.path().join("a");
        write_include(&ours, &include_text(1, "x")).unwrap();
        remove_include(&ours);
        assert!(!ours.exists());
        let theirs = dir.path().join("b");
        std::fs::write(&theirs, "[user]\n").unwrap();
        remove_include(&theirs);
        assert!(theirs.exists());
    }
}
