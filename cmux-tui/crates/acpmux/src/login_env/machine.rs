//! Literal machine environment declarations, for local child processes only.
//!
//! No shell evaluates this file. Values are read afresh, never cached or exposed
//! through the generic login environment, so replacing/removing the file rotates
//! or revokes them without a daemon restart.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

const MAX_BYTES: u64 = 4 << 20;
const MAX_VALUE_BYTES: usize = 131_072;

// Names only: a daemon may itself have inherited an older delivered value.
// Keep clearing those keys on local children after the file revokes them.
static OBSERVED: RwLock<BTreeSet<String>> = RwLock::new(BTreeSet::new());

pub(super) fn names() -> BTreeSet<String> {
    OBSERVED.read().unwrap_or_else(|e| e.into_inner()).clone()
}

pub(super) fn read() -> BTreeMap<String, String> {
    let Some(home) = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(dirs::home_dir)
        .filter(|path| path.is_absolute())
    else {
        return BTreeMap::new();
    };
    let values = read_in(&home);
    OBSERVED.write().unwrap_or_else(|e| e.into_inner()).extend(values.keys().cloned());
    values
}

#[cfg(not(unix))]
fn read_in(_home: &Path) -> BTreeMap<String, String> {
    // No owner-only ACL check is implemented on this platform.
    BTreeMap::new()
}

#[cfg(unix)]
fn read_in(home: &Path) -> BTreeMap<String, String> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let Ok(file) = options.open(home.join(".config/cmux/machine.env")) else {
        return BTreeMap::new();
    };
    let Ok(meta) = file.metadata() else { return BTreeMap::new() };
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return BTreeMap::new();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
            return BTreeMap::new();
        }
    }
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    if file.take(MAX_BYTES + 1).read_to_end(&mut bytes).is_err() || bytes.len() as u64 > MAX_BYTES {
        return BTreeMap::new();
    }
    let Ok(text) = std::str::from_utf8(&bytes) else { return BTreeMap::new() };
    parse(text).unwrap_or_default()
}

/// Only the receiver's `export NAME='literal'` format. Older machine files
/// also contain comments, unset statements and a secrets-file hook: those
/// are not declarations and are never evaluated here. A malformed export
/// refuses this file as a whole, without echoing any of its contents.
fn parse(text: &str) -> Option<BTreeMap<String, String>> {
    let mut vars = BTreeMap::new();
    let mut rest = text;
    while !rest.is_empty() {
        let Some(declaration) = rest.strip_prefix("export ") else {
            rest = rest.split_once('\n').map_or("", |(_, tail)| tail);
            continue;
        };
        let (name, literal) = declaration.split_once('=')?;
        if name.contains('\n') {
            return None;
        }
        let (value, tail) = literal_value(literal)?;
        rest = if tail.is_empty() { "" } else { tail.strip_prefix('\n')? };
        if value.len() > MAX_VALUE_BYTES || value.contains('\0') {
            return None;
        }
        if allowed_name(name) {
            vars.insert(name.to_owned(), value);
        }
    }
    Some(vars)
}

fn literal_value(text: &str) -> Option<(String, &str)> {
    let mut rest = text.strip_prefix('\'')?;
    let mut value = String::new();
    loop {
        let (literal, tail) = rest.split_once('\'')?;
        value.push_str(literal);
        if let Some(inside) = tail.strip_prefix("\\''") {
            rest = inside;
            value.push('\'');
        } else {
            return Some((value, tail));
        }
    }
}

fn allowed_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    let valid = bytes.len() <= 128
        && bytes.first().is_some_and(|b| b.is_ascii_alphabetic() || *b == b'_')
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_');
    valid
        && !["LD_", "DYLD_", "BASH_FUNC_", "GIT_CONFIG_", "CMUX_", "ACPMUX_"]
            .iter()
            .any(|prefix| name.starts_with(prefix))
        && !matches!(
            name,
            "PATH"
                | "HOME"
                | "SHELL"
                | "ZDOTDIR"
                | "GCONV_PATH"
                | "GIT_SSH_COMMAND"
                | "GIT_SSH"
                | "GIT_EXEC_PATH"
                | "BASH_ENV"
                | "ENV"
                | "SHELLOPTS"
                | "BASHOPTS"
                | "IFS"
                | "PROMPT_COMMAND"
                | "PS4"
                | "NODE_OPTIONS"
                | "NODE_PATH"
                | "PYTHONPATH"
                | "PYTHONHOME"
                | "PYTHONSTARTUP"
                | "PYTHONWARNINGS"
                | "JAVA_TOOL_OPTIONS"
                | "_JAVA_OPTIONS"
                | "JDK_JAVA_OPTIONS"
                | "RUBYOPT"
                | "RUBYLIB"
                | "PERL5OPT"
                | "PERL5LIB"
                | "PERL5DB"
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_only_literals_without_interpreting_shell_expressions() {
        let vars = parse("# comment\nexport DEMO_KEY='a'\\''b\\c$HOME$(touch nope)`nope`'\nexport EMPTY=''\nunset DEMO_KEY\n. /some/script\n").unwrap();
        assert_eq!(vars["DEMO_KEY"], "a'b\\c$HOME$(touch nope)`nope`");
        assert_eq!(vars["EMPTY"], "");
        assert_eq!(parse("export MULTI='line1\nline2'\n").unwrap()["MULTI"], "line1\nline2");
        for bad in [
            "export KEY=$(command)",
            "export KEY='a'; command",
            "export KEY=\"$HOME\"",
            "export KEY='a\nb",
        ] {
            assert!(parse(bad).is_none());
        }
    }

    #[test]
    fn loader_and_bootstrap_names_never_enter_the_overlay() {
        for name in [
            "LD_PRELOAD",
            "DYLD_INSERT_LIBRARIES",
            "BASH_ENV",
            "PYTHONSTARTUP",
            "JAVA_TOOL_OPTIONS",
            "PERL5DB",
            "ZDOTDIR",
            "GCONV_PATH",
            "GIT_SSH_COMMAND",
            "GIT_CONFIG_COUNT",
            "PATH",
            "HOME",
            "SHELL",
            "CMUX_ACCESS_TOKEN",
            "ACPMUX_HOME",
            "9BAD",
        ] {
            assert!(!allowed_name(name), "{name}");
        }
        assert!(allowed_name("API_TOKEN"));
        assert_eq!(parse("export HOME='/other'\nexport API_TOKEN='synthetic'\n").unwrap().len(), 1);
    }

    #[test]
    #[cfg(unix)]
    fn requires_a_private_owned_regular_file_and_reads_replacements() {
        use std::os::unix::fs::PermissionsExt as _;
        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join(".config/cmux");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("machine.env");
        std::fs::write(&path, "export DEMO_KEY='first'\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(read_in(home.path())["DEMO_KEY"], "first");
        let next = dir.join("next");
        std::fs::write(&next, "export DEMO_KEY='other'\n").unwrap();
        std::fs::set_permissions(&next, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::rename(&next, &path).unwrap();
        assert_eq!(read_in(home.path())["DEMO_KEY"], "other");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_in(home.path()).is_empty());
        std::fs::rename(&path, &next).unwrap();
        std::os::unix::fs::symlink(&next, &path).unwrap();
        assert!(read_in(home.path()).is_empty());
        std::fs::remove_file(&path).unwrap();
        assert!(read_in(home.path()).is_empty());
    }
}
