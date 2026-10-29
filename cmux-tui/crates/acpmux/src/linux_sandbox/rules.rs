//! Seatbelt file policy, staged independently of Linux sandbox activation.
//! All loops consume finite input or collections; parsing stops at EOF/error,
//! with at most 32 nested expressions and 64 KiB of profile text. No I/O occurs.
//! Paths must already be resolved in the target's view, including symlinks.
//! Stricter than Seatbelt: noncanonical, non-UTF-8 and newline paths are refused;
//! unmatched writes are denied, and unsupported file rules reject the profile.

// No production caller until the Linux sandbox wiring lands.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use regex::Regex;

pub(crate) type Params = BTreeMap<String, PathBuf>;

#[derive(Debug, thiserror::Error)]
#[error("unsupported Seatbelt profile: {0}")]
pub(crate) struct ParseError(pub(crate) String);

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Denied {
    pub(crate) rule: String,
}

#[derive(Debug)]
pub(crate) struct WritePolicy {
    pub(crate) skipped: Vec<String>,
    writes: Vec<WriteRule>,
    reads: Vec<PathBuf>,
}

#[derive(Debug)]
struct WriteRule {
    allow: bool,
    text: String,
    filters: Vec<Filter>,
}

#[derive(Debug)]
enum Filter {
    Subpath(PathBuf),
    Literal(PathBuf),
    Regex(Regex),
}

impl WritePolicy {
    /// Use `crate::hub::remote_sandbox::PROFILE` for the production policy.
    /// Parse both write rules and read masks; unsupported file forms fail closed.
    /// The loop ends at EOF or the first invalid form.
    pub(crate) fn from_profile(sb: &str, params: &Params) -> Result<Self, ParseError> {
        if sb.len() > 64 * 1024 {
            return Err(ParseError("profile exceeds 64 KiB".into()));
        }
        let mut out = Self { skipped: Vec::new(), writes: Vec::new(), reads: Vec::new() };
        let mut reader = Reader(sb);
        reader.space();
        while !reader.0.is_empty() {
            let start = reader.0;
            let node = reader.expr(0)?;
            let text = &start[..start.len() - reader.0.len()];
            let items = node.list()?;
            match items {
                [Expr::Atom("version"), Expr::Atom("1")]
                | [Expr::Atom("allow"), Expr::Atom("default")] => {
                    out.skipped.push(text.into());
                }
                [Expr::Atom(action @ ("allow" | "deny")), Expr::Atom(op), filters @ ..] => {
                    let allow = *action == "allow";
                    match *op {
                        "file-write*" | "file-read*" => {
                            if filters.is_empty() || (*op == "file-read*" && allow) {
                                return Err(ParseError(text.into()));
                            }
                            let filters = filters
                                .iter()
                                .map(|f| filter(f, params))
                                .collect::<Result<Vec<_>, _>>()?;
                            if *op == "file-write*" {
                                out.writes.push(WriteRule { allow, text: text.into(), filters });
                            } else {
                                for f in filters {
                                    match f {
                                        Filter::Subpath(p) | Filter::Literal(p) => {
                                            out.reads.push(p)
                                        }
                                        Filter::Regex(_) => return Err(ParseError(text.into())),
                                    }
                                }
                            }
                        }
                        _ if skipped(op, filters, allow) => {
                            out.skipped.push(text.into());
                        }
                        _ => return Err(ParseError(text.into())),
                    }
                }
                _ => return Err(ParseError(text.into())),
            }
            reader.space();
        }
        Ok(out)
    }

    /// The caller must resolve symlinks in the target's view before checking.
    /// The reverse scan stops at the first matching rule or after all rules.
    pub(crate) fn check(&self, path: &Path) -> Result<(), Denied> {
        let text = canonical_text(path).map_err(|e| Denied { rule: e.0 })?;
        for rule in self.writes.iter().rev() {
            if rule.filters.iter().any(|f| match f {
                Filter::Subpath(p) => path.starts_with(p),
                Filter::Literal(p) => path == p,
                Filter::Regex(r) => r.is_match(text),
            }) {
                return if rule.allow { Ok(()) } else { Err(Denied { rule: rule.text.clone() }) };
            }
        }
        Err(Denied { rule: "implicit deny: no matching file-write* rule".into() })
    }

    /// Read masks from a successfully parsed profile, without filesystem I/O.
    pub(crate) fn read_denies(&self) -> Vec<PathBuf> {
        self.reads.clone()
    }
}

/// Non-file operations belong to other layers, but never skip executable Scheme
/// expressions: a nested expression could itself install a file rule.
fn skipped(op: &str, filters: &[Expr<'_>], allow: bool) -> bool {
    if !allow && filters.is_empty() {
        return matches!(
            op,
            "file-link"
                | "file-mount"
                | "user-preference-write"
                | "mach-lookup"
                | "job-creation"
                | "lsopen"
                | "appleevent-send"
                | "signal"
                | "mach-priv-task-port"
                | "network-bind"
                | "network-inbound"
                | "network-outbound"
        );
    }
    !filters.is_empty()
        && filters.iter().all(|f| match f {
            Expr::List(v) => match (op, v.as_slice()) {
                ("mach-lookup", [Expr::Atom("global-name"), Expr::Text(_)]) => true,
                ("signal", [Expr::Atom("target"), Expr::Atom("same-sandbox")]) => true,
                ("network-outbound", [Expr::Atom("remote"), Expr::Atom("ip"), Expr::Text(_)]) => {
                    true
                }
                (
                    "network-outbound",
                    [Expr::Atom("remote"), Expr::Atom("unix-socket"), Expr::List(v)],
                ) => {
                    matches!(v.as_slice(), [Expr::Atom("path-literal"), Expr::Text(_)])
                }
                _ => false,
            },
            _ => false,
        })
}

fn canonical_text(path: &Path) -> Result<&str, ParseError> {
    let valid = path.to_str().filter(|s| {
        s.starts_with('/')
            && !s.contains(['\0', '\n', '\r'])
            && (*s == "/" || s[1..].split('/').all(|p| !matches!(p, "" | "." | "..")))
    });
    valid.ok_or_else(|| {
        ParseError("path must be canonical absolute UTF-8 without NUL/newlines".into())
    })
}

fn path_value(expr: &Expr<'_>, params: &Params) -> Result<String, ParseError> {
    match expr {
        Expr::Text(s) => Ok(s.clone()),
        Expr::List(v) => match v.as_slice() {
            [Expr::Atom("param"), Expr::Text(name)]
                if matches!(
                    name.as_str(),
                    "CWD" | "TMPDIR" | "HOME" | "CLAUDE_TMP_PROJECT" | "CLAUDE_PROJECT"
                ) =>
            {
                let p =
                    params.get(name).ok_or_else(|| ParseError(format!("missing param {name}")))?;
                Ok(canonical_text(p)?.into())
            }
            [Expr::Atom("string-append"), param @ Expr::List(v), Expr::Text(suffix)]
                if matches!(v.as_slice(), [Expr::Atom("param"), Expr::Text(_)]) =>
            {
                Ok(path_value(param, params)? + suffix)
            }
            _ => Err(ParseError("unsupported path expression".into())),
        },
        _ => Err(ParseError("expected a path string".into())),
    }
}

fn filter(expr: &Expr<'_>, params: &Params) -> Result<Filter, ParseError> {
    match expr.list()? {
        [Expr::Atom(kind @ ("subpath" | "literal")), value] => {
            let p = PathBuf::from(path_value(value, params)?);
            canonical_text(&p)?;
            Ok(if *kind == "subpath" { Filter::Subpath(p) } else { Filter::Literal(p) })
        }
        [Expr::Atom("regex"), Expr::Raw(s)] => Ok(Filter::Regex(profile_regex(s)?)),
        _ => Err(ParseError("unsupported file predicate".into())),
    }
}

/// Accept only the regular-expression syntax used here, plus explicit '^'.
/// The loop stops when the finite regex input is exhausted or syntax is refused.
fn profile_regex(s: &str) -> Result<Regex, ParseError> {
    let bad = || ParseError(format!("unsupported regex {s:?}"));
    let mut chars = s.chars();
    let mut previous = None;
    while let Some(c) = chars.next() {
        if c == '\\' {
            if chars.next() != Some('.') {
                return Err(bad());
            }
            previous = None;
            continue;
        }
        if !(c.is_ascii_alphanumeric() || "/_-().|*+?^$".contains(c))
            || (c == '?' && previous == Some('('))
            || (matches!(c, '*' | '+' | '?')
                && previous.is_some_and(|p| matches!(p, '*' | '+' | '?')))
        {
            return Err(bad());
        }
        previous = Some(c);
    }
    // No anchoring is added: Seatbelt searches the entire absolute path.
    Regex::new(s).map_err(|e| ParseError(format!("regex {s:?}: {e}")))
}

#[derive(Debug)]
enum Expr<'a> {
    Atom(&'a str),
    Text(String),
    Raw(String),
    List(Vec<Expr<'a>>),
}

impl<'a> Expr<'a> {
    fn list(&self) -> Result<&[Expr<'a>], ParseError> {
        match self {
            Self::List(v) => Ok(v),
            _ => Err(ParseError("expected a list".into())),
        }
    }
}

struct Reader<'a>(&'a str);

impl<'a> Reader<'a> {
    /// Stops at the next token or EOF, consuming whitespace and each comment.
    fn space(&mut self) {
        loop {
            self.0 = self.0.trim_start_matches(|c: char| c.is_ascii_whitespace());
            if !self.0.starts_with(';') {
                break;
            }
            self.0 = self.0.split_once('\n').map_or("", |(_, rest)| rest);
        }
    }

    /// Each iteration consumes a character or child; EOF, ')' or error stops it.
    /// Recursion is capped at 32, including for ignored non-file forms.
    fn expr(&mut self, depth: usize) -> Result<Expr<'a>, ParseError> {
        if depth >= 32 {
            return Err(ParseError("expression nesting exceeds 32".into()));
        }
        self.space();
        if self.0.starts_with('(') {
            self.0 = &self.0[1..];
            let mut children = Vec::new();
            loop {
                self.space();
                if self.0.starts_with(')') {
                    self.0 = &self.0[1..];
                    return Ok(Expr::List(children));
                }
                children.push(self.expr(depth + 1)?);
            }
        }
        let raw = self.0.starts_with("#\"");
        if raw || self.0.starts_with('"') {
            self.0 = &self.0[if raw { 2 } else { 1 }..];
            let mut value = String::new();
            while let Some(c) = self.0.chars().next() {
                self.0 = &self.0[c.len_utf8()..];
                match c {
                    '"' => return Ok(if raw { Expr::Raw(value) } else { Expr::Text(value) }),
                    '\\' if !raw => {
                        let c = self
                            .0
                            .chars()
                            .next()
                            .filter(|c| matches!(*c, '\\' | '"'))
                            .ok_or_else(|| ParseError("unsupported string escape".into()))?;
                        self.0 = &self.0[c.len_utf8()..];
                        value.push(c);
                    }
                    _ => value.push(c),
                }
            }
            return Err(ParseError("unterminated string".into()));
        }
        let end = self
            .0
            .find(|c: char| c.is_ascii_whitespace() || "();\"#".contains(c))
            .unwrap_or(self.0.len());
        if end == 0 {
            return Err(ParseError("expected expression".into()));
        }
        let (atom, rest) = self.0.split_at(end);
        self.0 = rest;
        Ok(Expr::Atom(atom))
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
            ("/elsewhere/.git/HEAD", true), // profile exception; bwrap constrains actual writes
            ("/home/u/work/not.git/HEAD", false),
            ("/home/u/.claude/projects/project/t.jsonl", true),
            ("/home/u/.claude/projects/project/CLAUDE.md", true),
            ("/home/u/.claude/projects/project/memory", false),
            ("/home/u/.claude/projects/project/memory/m.md", false),
            ("/home/u/.claude/projects/project/memory/.git/HEAD", false),
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
            r#"(allow file-write* (regex #"/a.*?$"))"#,
            r#"(allow file-write* (regex #"/a{2}$"))"#,
            r#"(allow file-write* (regex #"("))"#,
            r#"(allow file-write* (literal "/a\q"))"#,
            r#"(if #t (allow file-write* (subpath "/")))"#,
            r#"(allow network-outbound (begin (deny file-write* (subpath "/")) (remote ip "*:443")))"#,
            r#"(deny signal (deny file-read* (literal "/secret")))"#,
            r#"(allow mach-lookup (global-name (param "HOME")))"#,
            r#"(allow file-write* (subpath (string-append "/a" "/b")))"#,
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
            "/home/u/work/.git/a\nb/config",
            "/home/u/work/a\rb",
        ] {
            assert!(policy.check(Path::new(path)).is_err(), "{path:?}");
        }
        let invalid = std::ffi::OsStr::from_bytes(b"/home/u/work/\xff/CLAUDE.md");
        assert!(policy.check(Path::new(invalid)).is_err());
        let mut invalid = params();
        invalid.insert("CWD".into(), "/home/u/work/../elsewhere".into());
        assert!(WritePolicy::from_profile(PROFILE, &invalid).is_err());
    }

    #[test]
    fn parser_limits_and_unterminated_input_fail_closed() {
        for sb in [
            " ".repeat(64 * 1024 + 1),
            format!("{}{}", "(".repeat(40), ")".repeat(40)),
            "(allow file-write* (literal \"unterminated".into(),
            "(allow file-write* (regex #\"unterminated".into(),
            "(allow file-write* (literal \"/a\")) )".into(),
        ] {
            assert!(WritePolicy::from_profile(&sb, &params()).is_err());
        }
        let policy = WritePolicy::from_profile(";; comment without a newline", &params()).unwrap();
        assert!(policy.check(Path::new("/")).is_err());
    }

    #[test]
    fn params_are_data_and_read_masks_follow_home() {
        let mut params = params();
        params.insert("CWD".into(), "/work/a;() \"quoted\" \\name".into());
        params.insert("HOME".into(), "/different-home".into());
        let policy = WritePolicy::from_profile(PROFILE, &params).unwrap();
        assert!(policy.check(&params["CWD"].join("plain.txt")).is_ok());
        assert!(policy.check(&params["CWD"].join(".git/config")).is_err());
        assert!(policy.read_denies().contains(&PathBuf::from("/different-home/.ssh")));
        assert!(!policy.read_denies().contains(&PathBuf::from("/home/u/.ssh")));
        let escaped = r#"(allow file-write* (literal "/a\"b\\c"))"#;
        let policy = WritePolicy::from_profile(escaped, &params).unwrap();
        assert!(policy.check(Path::new("/a\"b\\c")).is_ok());
    }
}
