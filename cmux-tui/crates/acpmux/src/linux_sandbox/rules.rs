//! Seatbelt file policy, staged independently of Linux sandbox activation.
//! Test loops terminate after their finite input tables are exhausted.

// No production caller until the Linux sandbox wiring lands.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub(crate) type Params = BTreeMap<String, PathBuf>;

#[derive(Debug)]
pub(crate) struct ParseError(pub(crate) String);

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Denied {
    pub(crate) rule: String,
}

#[derive(Debug)]
pub(crate) struct WritePolicy {
    pub(crate) skipped: Vec<String>,
}

impl WritePolicy {
    /// Parse both write rules and read masks; unsupported file forms fail closed.
    pub(crate) fn from_profile(_sb: &str, _params: &Params) -> Result<Self, ParseError> {
        Err(ParseError("Seatbelt parser not implemented".into()))
    }

    /// The caller must resolve symlinks in the target's view before checking.
    pub(crate) fn check(&self, _path: &Path) -> Result<(), Denied> {
        Err(Denied { rule: "Seatbelt parser not implemented".into() })
    }

    /// Read masks from a successfully parsed profile, without filesystem I/O.
    pub(crate) fn read_denies(&self) -> Vec<PathBuf> {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::remote_sandbox::PROFILE;

    fn params() -> Params {
        [
            ("CWD", "/home/u/work"),
            ("TMPDIR", "/tmp/acpmux-session"),
            ("HOME", "/home/u"),
            ("CLAUDE_TMP_PROJECT", "/tmp/claude-1000/project"),
            ("CLAUDE_PROJECT", "/home/u/.claude/projects/project"),
        ]
        .into_iter()
        .map(|(k, v)| (k.into(), v.into()))
        .collect()
    }

    #[test]
    fn checked_in_profile_parses_and_lists_skipped_rules() {
        let policy = WritePolicy::from_profile(PROFILE, &params()).unwrap();
        let skipped: Vec<_> = policy.skipped.iter().map(String::as_str).collect();
        assert_eq!(
            skipped,
            vec![
                "(version 1)",
                "(allow default)",
                "(deny file-link)",
                "(deny file-mount)",
                "(deny user-preference-write)",
                "(deny mach-lookup)",
                "(allow mach-lookup\n  (global-name \"com.apple.cfprefsd.agent\")\n  (global-name \"com.apple.system.logger\"))",
                "(deny job-creation)",
                "(deny lsopen)",
                "(deny appleevent-send)",
                "(deny signal)",
                "(allow signal (target same-sandbox))",
                "(deny mach-priv-task-port)",
                "(deny network-bind)",
                "(deny network-inbound)",
                "(deny network-outbound)",
                "(allow network-outbound (remote ip \"*:443\") (remote ip \"*:80\"))",
                "(allow network-outbound (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")))",
                "(deny network-outbound (remote ip \"localhost:*\"))",
            ]
        );
    }

    #[test]
    fn checked_in_profile_write_decisions() {
        let policy = WritePolicy::from_profile(PROFILE, &params()).unwrap();
        for (path, allowed) in [
            ("/home/u/work/a.txt", true),
            ("/home/u/work", true),
            ("/home/u/work-other/a.txt", false),
            ("/home/u/work/.git", false), // create, rename and remove use this same check
            ("/home/u/work/.git/objects/x", true),
            ("/home/u/work/sub/.git/hooks/pre-commit", false),
            ("/home/u/work/.git/worktrees/w/config.worktree", false),
            ("/home/u/work/.git/commondir", false),
            ("/home/u/work/.git/worktrees/w/gitdir", false),
            ("/home/u/work/x/.claude/settings.json", false),
            ("/home/u/work/deep/CLAUDE.md", false),
            ("/home/u/work/HEAD", false),
            ("/home/u/work/.git/HEAD", true),
            ("/home/u/work/.git/refs/heads/HEAD", true),
            ("/home/u/work/.git/hooks/HEAD", true), // last matching rule wins
            ("/home/u/work/not.git/HEAD", false),
            ("/home/u/.claude/projects/project/t.jsonl", true),
            ("/home/u/.claude/projects/project/CLAUDE.md", true),
            ("/home/u/.claude/projects/project/memory", false),
            ("/home/u/.claude/projects/project/memory/m.md", false),
            ("/home/u/.claude/projects/project/memory-other/m.md", true),
            ("/home/u/.claude/projects/other/t.jsonl", false),
            ("/home/u/.bashrc", false),
            ("/tmp/x", false),
            ("/tmp/acpmux-session/file", true),
            ("/tmp/claude-1000/project/file", true),
            ("/tmp/claude-1000/other/file", false),
            ("/dev/null", true),
            ("/dev/null/child", false),
            ("/dev/zero", true),
            ("/dev/tty", true),
            ("/dev/dtracehelper", true), // absent on Linux, harmless profile literal
            ("/dev/fd/1", true),
            ("/dev/fd-other/1", false),
        ] {
            assert_eq!(policy.check(Path::new(path)).is_ok(), allowed, "{path}");
        }
    }

    #[test]
    fn persistence_names_are_denied_at_every_depth() {
        let policy = WritePolicy::from_profile(PROFILE, &params()).unwrap();
        for prefix in ["/home/u/work", "/home/u/work/a/b", "/tmp/acpmux-session"] {
            for name in [
                ".git",
                ".git/config",
                ".git/worktrees/w/config.worktree",
                ".git/hooks/x",
                ".codex/auth.json",
                ".vscode/x",
                ".zed/x",
                ".idea/x",
                ".husky/x",
                ".githooks/x",
                ".mcp.json",
                ".envrc",
                ".pre-commit-config.yaml",
                "lefthook.yml",
                ".tool-versions",
                "mise.toml",
                ".mise.local.toml",
                ".mise/config.toml",
                ".config/mise/x",
                ".hg/hgrc",
                ".cursor/x",
                ".windsurf/x",
                ".cursorrules",
                ".github/copilot-instructions.md",
                "CLAUDE.md",
                "AGENTS.md",
                "CLAUDE.local.md",
                "AGENTS.override.md",
                "GEMINI.md",
            ] {
                let path = Path::new(prefix).join(name);
                assert!(policy.check(&path).is_err(), "{}", path.display());
            }
        }
        // Regex search is unanchored, while escaped dots and '$' remain meaningful.
        for name in ["not.git/config", "xclaude/settings.json", "CLAUDE.md.bak", "HEAD.bak"] {
            assert!(policy.check(&Path::new("/home/u/work").join(name)).is_ok(), "{name}");
        }
    }

    #[test]
    fn read_masks_come_from_the_profile_without_checking_existence() {
        let policy = WritePolicy::from_profile(PROFILE, &params()).unwrap();
        let expected: Vec<PathBuf> = [
            "/home/u/.ssh",
            "/home/u/.secrets",
            "/home/u/.aws",
            "/home/u/.gnupg",
            "/home/u/.kube",
            "/home/u/.config/gh",
            "/home/u/.netrc",
            "/home/u/.git-credentials",
            "/home/u/.npmrc",
            "/home/u/.codex/auth.json",
            "/home/u/.config/gcloud",
            "/home/u/.azure",
            "/home/u/.docker/config.json",
            "/home/u/Library/Keychains",
            "/Library/Keychains",
            "/home/u/Library/Cookies",
            "/home/u/Library/Application Support/Google/Chrome",
            "/home/u/Library/Application Support/Firefox",
            "/home/u/Library/Safari",
        ]
        .into_iter()
        .map(PathBuf::from)
        .collect();
        assert_eq!(policy.read_denies(), expected);
        let custom = r#"(deny file-read* (literal (string-append (param "HOME") "/new-secret")))"#;
        assert_eq!(
            WritePolicy::from_profile(custom, &params()).unwrap().read_denies(),
            vec![PathBuf::from("/home/u/new-secret")]
        );
    }

    #[test]
    fn last_matching_rule_is_reported_verbatim() {
        let sb = r#"; a comment
            (deny file-write* (subpath "/"))
            (allow file-write* (subpath "/a"))
            (deny file-write* (literal "/a/no"))
            (allow file-write* (regex #"/yes$"))"#;
        let policy = WritePolicy::from_profile(sb, &params()).unwrap();
        assert_eq!(
            policy.check(Path::new("/a/no")).unwrap_err().rule,
            r#"(deny file-write* (literal "/a/no"))"#
        );
        assert_eq!(
            policy.check(Path::new("/ab/no")).unwrap_err().rule,
            r#"(deny file-write* (subpath "/"))"#
        );
        assert!(policy.check(Path::new("/elsewhere/yes")).is_ok());
        let empty = WritePolicy::from_profile("", &params()).unwrap();
        assert!(empty.check(Path::new("/a")).is_err(), "no match defaults to deny");
    }

    #[test]
    fn unsupported_or_malformed_file_rules_fail_closed() {
        for sb in [
            "(allow file-write*)",
            r#"(deny file-read* (regex #"/secret$"))"#,
            r#"(allow file-read* (literal "/secret"))"#,
            r#"(allow file-write* (require-any (literal "/a")))"#,
            r#"(allow file-write-data (literal "/a"))"#,
            r#"(deny file-read-metadata (literal "/a"))"#,
            r#"(allow file-write* file-read* (literal "/a"))"#,
            r#"(allow file-write* (subpath (param "UNKNOWN")))"#,
            r#"(allow file-write* (subpath "relative"))"#,
            r#"(allow file-write* (subpath "/a/../b"))"#,
            r#"(allow file-write* (literal "/a" "/b"))"#,
            r#"(allow file-write* (regex "/a$"))"#,
            r#"(allow file-write* (regex #"/\w+$"))"#,
            r#"(allow file-write* (regex #"(?i)/a$"))"#,
            r#"(allow file-write* (regex #"[a-z]"))"#,
            r#"(allow file-write* (regex #"("))"#,
            r#"(allow file-write* (literal "/a\q"))"#,
            r#"(if #t (allow file-write* (subpath "/")))"#,
            "(unknown-operation)",
            "(version 2)",
            "(deny default)",
            "(allow file-write*",
            ")",
            "garbage",
            "(deny file-read*)",
        ] {
            assert!(WritePolicy::from_profile(sb, &params()).is_err(), "accepted {sb}");
        }
        let mut missing = params();
        missing.remove("CWD");
        assert!(WritePolicy::from_profile(PROFILE, &missing).is_err());
    }

    #[test]
    fn comments_and_string_contents_do_not_change_form_boundaries() {
        let sb = r#";; ignore (deny file-write* (subpath "/"))
            (allow file-write* ; another comment
                (literal "/a;() with spaces")
                (regex #"^/only/here$"))"#;
        let policy = WritePolicy::from_profile(sb, &params()).unwrap();
        assert!(policy.check(Path::new("/a;() with spaces")).is_ok());
        assert!(policy.check(Path::new("/only/here")).is_ok());
        assert!(policy.check(Path::new("/prefix/only/here")).is_err());
        assert!(policy.check(Path::new("/only/here/child")).is_err());
    }

    #[test]
    fn noncanonical_paths_and_non_utf8_paths_are_refused() {
        use std::os::unix::ffi::OsStrExt;
        let policy = WritePolicy::from_profile(PROFILE, &params()).unwrap();
        for path in [
            "relative",
            "",
            "/home/u/work/../.bashrc",
            "/home/u/work/./HEAD",
            "/home/u/work//HEAD",
            "/home/u/work/HEAD/",
            "/home/u/work/a\0b",
        ] {
            assert!(policy.check(Path::new(path)).is_err(), "{path:?}");
        }
        let invalid = std::ffi::OsStr::from_bytes(b"/home/u/work/\xff/CLAUDE.md");
        assert!(policy.check(Path::new(invalid)).is_err());
        let mut invalid = params();
        invalid.insert("CWD".into(), "/home/u/work/../elsewhere".into());
        assert!(WritePolicy::from_profile(PROFILE, &invalid).is_err());
    }
}
