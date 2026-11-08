//! The pure parts of a pull request review: its link, which remote names its
//! repository, which lines of its diff GitHub takes a comment on, and the
//! review GitHub is sent.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

/// The lines of context GitHub's pull request diff shows around a change;
/// a comment can be left on a line it shows.
pub(super) const CONTEXT_LINES: &str = "--unified=3";

/// A pull request by its link: `https://github.com/OWNER/REPO/pull/N`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PullRef {
    pub owner: String,
    pub repo: String,
    pub number: u64,
}

impl PullRef {
    /// `https://github.com/OWNER/REPO/pull/N`, with anything after the number
    /// (`/files`, a query, a fragment) left out. Nothing else is a link.
    pub(super) fn parse(url: &str) -> Option<Self> {
        let rest = url.trim().strip_prefix("https://github.com/")?;
        let rest = rest.split(['?', '#']).next().unwrap_or_default();
        let mut parts = rest.split('/');
        let (owner, repo, pull, number) =
            (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
        let number: u64 = number.parse().ok().filter(|number| *number > 0)?;
        let name = |part: &str| {
            !part.is_empty()
                && part.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
                && part != "."
                && part != ".."
        };
        (pull == "pull" && name(owner) && name(repo)).then(|| Self {
            owner: owner.to_string(),
            repo: repo.to_string(),
            number,
        })
    }

    /// `OWNER/REPO`.
    pub(super) fn repository(&self) -> String {
        format!("{}/{}", self.owner, self.repo)
    }

    pub(super) fn url(&self) -> String {
        format!("https://github.com/{}/pull/{}", self.repository(), self.number)
    }

    /// Whether a remote's URL is this repository on github.com: HTTPS, SSH
    /// or scp form, with or without `.git`, case aside.
    pub(super) fn is_remote(&self, remote: &str) -> bool {
        let remote = remote.trim().to_ascii_lowercase();
        let path = [
            "https://github.com/",
            "http://github.com/",
            "ssh://git@github.com/",
            "git@github.com:",
        ]
        .iter()
        .find_map(|prefix| remote.strip_prefix(prefix));
        let Some(path) = path else { return false };
        let path = path.trim_end_matches('/');
        let path = path.strip_suffix(".git").unwrap_or(path);
        path == self.repository().to_ascii_lowercase()
    }
}

/// Which side of the diff a comment is on, as the diff page names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Side {
    /// The pull request's version of the file (GitHub's RIGHT).
    Additions,
    /// The base's version (GitHub's LEFT).
    Deletions,
}

impl Side {
    pub(super) fn parse(text: &str) -> Option<Self> {
        match text {
            "additions" | "new" | "right" => Some(Self::Additions),
            "deletions" | "old" | "left" => Some(Self::Deletions),
            _ => None,
        }
    }

    pub(super) fn page_name(self) -> &'static str {
        match self {
            Self::Additions => "additions",
            Self::Deletions => "deletions",
        }
    }

    fn github(self) -> &'static str {
        match self {
            Self::Additions => "RIGHT",
            Self::Deletions => "LEFT",
        }
    }
}

/// One file's hunks: each `(old start, old count, new start, new count)`,
/// and the file's path on the base side (another for a renamed file).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(super) struct Hunks {
    ranges: Vec<[u32; 4]>,
    pub old_path: Option<String>,
}

impl Hunks {
    /// The hunk headers of a unified diff of one file.
    pub(super) fn parse(diff: &str) -> Self {
        Self { ranges: diff.lines().filter_map(hunk_header).collect(), old_path: None }
    }

    /// Lines `start..=end` on `side` lie in one hunk.
    pub(super) fn covers(&self, side: Side, start: u32, end: u32) -> bool {
        start >= 1
            && start <= end
            && self.ranges(side).any(|(first, count)| start >= first && end < first + count)
    }

    /// The line ranges `side` shows, as `10-24, 80-95`; empty when none.
    pub(super) fn describe(&self, side: Side) -> String {
        let ranges: Vec<String> = self
            .ranges(side)
            .map(|(first, count)| match count {
                1 => first.to_string(),
                _ => format!("{first}-{}", first + count - 1),
            })
            .collect();
        ranges.join(", ")
    }

    fn ranges(&self, side: Side) -> impl Iterator<Item = (u32, u32)> + '_ {
        self.ranges
            .iter()
            .map(move |[old, old_count, new, new_count]| match side {
                Side::Additions => (*new, *new_count),
                Side::Deletions => (*old, *old_count),
            })
            .filter(|(_, count)| *count > 0)
    }
}

/// Each file's hunks in a whole unified diff (`git diff -M`), by the path
/// GitHub names it with: its new path, or its old one when it was deleted.
pub(super) fn file_hunks(diff: &str) -> BTreeMap<String, Hunks> {
    let mut files = BTreeMap::new();
    for section in diff.split("\ndiff --git ").filter(|section| !section.is_empty()) {
        let (mut old, mut new) = (None, None);
        for line in section.lines().take_while(|line| !line.starts_with("@@ ")) {
            if let Some(path) = line.strip_prefix("--- ") {
                old = header_path(path, "a/");
            } else if let Some(path) = line.strip_prefix("+++ ") {
                new = header_path(path, "b/");
            }
        }
        if let Some(path) = new.clone().or_else(|| old.clone()) {
            let mut hunks = Hunks::parse(section);
            hunks.old_path = old;
            files.insert(path, hunks);
        }
    }
    files
}

/// The path a `---` or `+++` line names after its `a/` or `b/` prefix: git
/// ends a name with a space in it with a tab, and C-quotes a name with a
/// quote, backslash or control character in it. `/dev/null` is none.
fn header_path(text: &str, prefix: &str) -> Option<String> {
    let text = text.strip_suffix('\t').unwrap_or(text);
    let text = match text.strip_prefix('"').and_then(|quoted| quoted.strip_suffix('"')) {
        Some(quoted) => unquote(quoted)?,
        None => text.to_string(),
    };
    text.strip_prefix(prefix).map(str::to_string)
}

/// A C-quoted name's bytes: `\\`, `\"`, `\t`, `\n` and octal `\ooo`.
fn unquote(quoted: &str) -> Option<String> {
    let mut bytes = Vec::new();
    let mut rest = quoted.bytes();
    while let Some(byte) = rest.next() {
        if byte != b'\\' {
            bytes.push(byte);
            continue;
        }
        let escaped = match rest.next()? {
            b'n' => b'\n',
            b't' => b'\t',
            b'r' => b'\r',
            b'a' => 7,
            b'b' => 8,
            b'f' => 12,
            b'v' => 11,
            digit @ b'0'..=b'7' => {
                let mut value = u32::from(digit - b'0');
                for _ in 0..2 {
                    let digit = rest.next().filter(u8::is_ascii_digit)?;
                    value = value * 8 + u32::from(digit - b'0');
                }
                u8::try_from(value).ok()?
            }
            other => other,
        };
        bytes.push(escaped);
    }
    String::from_utf8(bytes).ok()
}

/// `@@ -a,b +c,d @@`: a missing count is 1.
fn hunk_header(line: &str) -> Option<[u32; 4]> {
    let rest = line.strip_prefix("@@ -")?;
    let (ranges, _) = rest.split_once(" @@")?;
    let (old, new) = ranges.split_once(" +")?;
    let range = |text: &str| -> Option<(u32, u32)> {
        match text.split_once(',') {
            Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
            None => Some((text.parse().ok()?, 1)),
        }
    };
    let ((old, old_count), (new, new_count)) = (range(old)?, range(new)?);
    Some([old, old_count, new, new_count])
}

/// The review GitHub is sent for `comments` (the diff page's records): an
/// inline comment for each that lies in its file's hunks, and the rest in the
/// review's body, so a draft on a line GitHub does not show is never lost.
pub(super) struct Review {
    pub payload: Value,
    /// The ids of the comments the review carries, inline or in its body.
    pub ids: Vec<String>,
    pub inline: usize,
    pub in_body: usize,
}

/// The hidden line a posted review's body carries for its post's key, so a
/// retry finds the review it may already have posted.
pub(super) fn marker(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    let id: String = digest.iter().take(12).map(|byte| format!("{byte:02x}")).collect();
    format!("<!-- cmux-review:{id} -->")
}

pub(super) fn review(
    head: &str,
    comments: &[&Map<String, Value>],
    hunks: &BTreeMap<String, Hunks>,
    marker: &str,
) -> Review {
    let mut inline = Vec::new();
    let mut outside = Vec::new();
    let mut ids = Vec::new();
    for comment in comments {
        let text = |name: &str| comment.get(name).and_then(Value::as_str).unwrap_or_default();
        let number = |name: &str| {
            comment.get(name).and_then(Value::as_u64).and_then(|value| u32::try_from(value).ok())
        };
        let (path, message) = (text("filePath"), text("message").trim());
        let (Some(start), Some(end)) = (number("startLine"), number("endLine")) else { continue };
        if path.is_empty() || message.is_empty() {
            continue;
        }
        let Some(side) = Side::parse(text("side")) else { continue };
        ids.push(text("id").to_string());
        if hunks.get(path).is_some_and(|hunks| hunks.covers(side, start, end)) {
            let mut entry =
                json!({"path": path, "body": message, "line": end, "side": side.github()});
            if start < end
                && let Some(fields) = entry.as_object_mut()
            {
                fields.insert("start_line".into(), json!(start));
                fields.insert("start_side".into(), json!(side.github()));
            }
            inline.push(entry);
        } else {
            let lines = if start < end { format!("{start}-{end}") } else { end.to_string() };
            outside.push(format!("- `{path}:{lines}`: {message}"));
        }
    }
    let (inline_count, in_body) = (inline.len(), outside.len());
    let body = if outside.is_empty() {
        marker.to_string()
    } else {
        format!("On lines outside this pull request's diff:\n\n{}\n\n{marker}", outside.join("\n"))
    };
    let payload = json!({"commit_id": head, "event": "COMMENT", "comments": inline, "body": body});
    Review { payload, ids, inline: inline_count, in_body }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_only_pull_request_links() {
        let parsed =
            PullRef::parse("https://github.com/manaflow-ai/cmux/pull/38100/files?w=1#x").unwrap();
        assert_eq!(
            parsed,
            PullRef { owner: "manaflow-ai".into(), repo: "cmux".into(), number: 38100 }
        );
        assert_eq!(parsed.url(), "https://github.com/manaflow-ai/cmux/pull/38100");
        for refused in [
            "https://github.com/manaflow-ai/cmux/issues/1",
            "https://github.com/manaflow-ai/cmux/pull/0",
            "https://github.com/manaflow-ai/cmux/pull/x",
            "http://github.com/manaflow-ai/cmux/pull/1",
            "https://gitlab.com/a/b/pull/1",
            "https://github.com/../cmux/pull/1",
            "https://github.com/a b/cmux/pull/1",
        ] {
            assert_eq!(PullRef::parse(refused), None, "{refused}");
        }
    }

    #[test]
    fn matches_remotes_of_its_repository() {
        let pull = PullRef::parse("https://github.com/Manaflow-AI/cmux/pull/1").unwrap();
        for remote in [
            "git@github.com:manaflow-ai/cmux.git",
            "https://github.com/manaflow-ai/cmux",
            "https://github.com/manaflow-ai/cmux.git/",
            "ssh://git@github.com/manaflow-ai/cmux.git",
        ] {
            assert!(pull.is_remote(remote), "{remote}");
        }
        for remote in
            ["git@github.com:manaflow-ai/cmux-platform.git", "https://example.com/manaflow-ai/cmux"]
        {
            assert!(!pull.is_remote(remote), "{remote}");
        }
    }

    #[test]
    fn hunks_cover_their_lines_on_each_side() {
        let hunks =
            Hunks::parse("diff --git a/f b/f\n@@ -10,7 +10,9 @@ fn\n x\n@@ -40 +42,0 @@\n-y\n");
        assert!(hunks.covers(Side::Additions, 10, 18));
        assert!(!hunks.covers(Side::Additions, 18, 19), "a range across a hunk's end");
        assert!(hunks.covers(Side::Deletions, 40, 40));
        assert!(!hunks.covers(Side::Additions, 42, 42), "a hunk with no new lines");
        assert_eq!(hunks.describe(Side::Additions), "10-18");
        assert_eq!(hunks.describe(Side::Deletions), "10-16, 40");
    }

    #[test]
    fn splits_a_whole_diff_by_file() {
        let diff = "diff --git a/a.rs b/a.rs\nindex 1..2 100644\n--- a/a.rs\n+++ b/a.rs\n@@ -1,2 +1,3 @@\n x\n+y\n\
                    diff --git a/old.rs b/new.rs\nsimilarity index 90%\n--- a/old.rs\n+++ b/new.rs\n@@ -5 +5 @@\n-a\n+b\n\
                    diff --git a/gone.rs b/gone.rs\ndeleted file mode 100644\n--- a/gone.rs\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n";
        let files = file_hunks(diff);
        assert_eq!(files.keys().collect::<Vec<_>>(), ["a.rs", "gone.rs", "new.rs"]);
        assert!(files["a.rs"].covers(Side::Additions, 1, 3));
        assert!(files["new.rs"].covers(Side::Deletions, 5, 5));
        assert!(files["gone.rs"].covers(Side::Deletions, 1, 2));
        assert_eq!(files["new.rs"].old_path.as_deref(), Some("old.rs"));
        assert_eq!(files["a.rs"].old_path.as_deref(), Some("a.rs"));
    }

    #[test]
    fn reads_names_with_spaces_and_quoted_names() {
        let diff = "diff --git a/has space.txt b/has space.txt\n--- a/has space.txt\t\n+++ b/has space.txt\t\n@@ -1 +1 @@\n-a\n+b\n\
                    diff --git \"a/q\\\"uote.txt\" \"b/q\\\"uote.txt\"\n--- \"a/q\\\"uote.txt\"\n+++ \"b/q\\\"uote.txt\"\n@@ -1 +1 @@\n-a\n+b\n\
                    diff --git a/caf\\303\\251 b/caf\\303\\251\n--- \"a/caf\\303\\251\"\n+++ \"b/caf\\303\\251\"\n@@ -1 +1 @@\n-a\n+b\n";
        let files = file_hunks(diff);
        assert_eq!(files.keys().collect::<Vec<_>>(), ["caf\u{e9}", "has space.txt", "q\"uote.txt"]);
    }

    #[test]
    fn review_puts_lines_outside_the_diff_in_its_body() {
        let comment = |id: &str, path: &str, side: &str, start: u32, end: u32| {
            json!({"id": id, "filePath": path, "side": side, "startLine": start, "endLine": end, "message": format!("m {id}")})
                .as_object()
                .unwrap()
                .clone()
        };
        let (a, b, c) = (
            comment("a", "src/x.rs", "additions", 11, 12),
            comment("b", "src/x.rs", "deletions", 40, 40),
            comment("c", "src/y.rs", "additions", 5, 5),
        );
        let hunks = BTreeMap::from([(
            "src/x.rs".to_string(),
            Hunks::parse("@@ -10,7 +10,9 @@\n@@ -40 +42,0 @@\n"),
        )]);
        let review = review("abc", &[&a, &b, &c], &hunks, "<!-- m -->");
        assert_eq!((review.inline, review.in_body), (2, 1));
        assert_eq!(review.ids, ["a", "b", "c"]);
        assert_eq!(review.payload["commit_id"], "abc");
        assert_eq!(review.payload["event"], "COMMENT");
        assert_eq!(
            review.payload["comments"][0],
            json!({"path": "src/x.rs", "body": "m a", "line": 12, "side": "RIGHT", "start_line": 11, "start_side": "RIGHT"})
        );
        assert_eq!(
            review.payload["comments"][1],
            json!({"path": "src/x.rs", "body": "m b", "line": 40, "side": "LEFT"})
        );
        assert_eq!(
            review.payload["body"],
            "On lines outside this pull request's diff:\n\n- `src/y.rs:5`: m c\n\n<!-- m -->"
        );
    }
}
