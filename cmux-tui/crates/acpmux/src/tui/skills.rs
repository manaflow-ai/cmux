//! Local SKILL.md discovery and explicit skill context for any ACP harness.
use anyhow::Result;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Skill {
    pub id: String,
    pub name: String,
    pub description: String,
    pub body: String,
    pub path: PathBuf,
}
const MAX_BYTES: u64 = 1_048_576;
impl Skill {
    pub fn discover(cwd: &Path, extra: &[String]) -> Vec<Self> {
        let home = dirs::home_dir().unwrap_or_default();
        discover_with_home(cwd, &home, extra)
    }
}
fn discover_with_home(cwd: &Path, home: &Path, extra: &[String]) -> Vec<Skill> {
    let mut roots = Vec::new();
    for rel in [
        ".claude/skills",
        ".agents/skills",
        ".codex/skills",
        ".config/opencode/skills",
        ".acpmux/skills",
    ] {
        roots.push(home.join(rel));
    }
    let mut ancestors = Vec::new();
    for dir in cwd.ancestors() {
        if dir == home {
            break;
        }
        ancestors.push(dir);
        if dir.join(".git").exists() {
            break;
        }
    }
    ancestors.reverse();
    for dir in ancestors {
        for rel in [
            ".claude/skills",
            ".agents/skills",
            ".codex/skills",
            ".opencode/skills",
            ".acpmux/skills",
        ] {
            roots.push(dir.join(rel));
        }
    }
    for s in extra {
        roots.push(if let Some(p) = s.strip_prefix("~/") { home.join(p) } else { cwd.join(s) });
    }
    let mut found = BTreeMap::new();
    for root in roots {
        scan_root(&root, 0, &mut HashSet::new(), &mut found);
    }
    found.into_values().collect()
}
fn scan_root(
    root: &Path,
    depth: usize,
    visited: &mut HashSet<PathBuf>,
    found: &mut BTreeMap<String, Skill>,
) {
    if depth > 12 {
        return;
    }
    let Ok(canonical) = fs::canonicalize(root) else { return };
    if !visited.insert(canonical) {
        return;
    }
    let Ok(entries) = fs::read_dir(root) else { return };
    let mut paths: Vec<_> = entries.flatten().map(|e| e.path()).collect();
    paths.sort();
    for path in paths {
        if path.is_file()
            && depth == 0
            && path.extension().and_then(|e| e.to_str()) == Some("md")
            && path.file_name().and_then(|n| n.to_str()) != Some("SKILL.md")
        {
            if let Some(s) =
                parse_skill(&path, path.file_stem().and_then(|n| n.to_str()).unwrap_or(""))
            {
                found.insert(s.id.clone(), s);
            }
        } else if path.is_dir() {
            let file = path.join("SKILL.md");
            if file.is_file() {
                if let Some(s) =
                    parse_skill(&file, path.file_name().and_then(|n| n.to_str()).unwrap_or(""))
                {
                    found.insert(s.id.clone(), s);
                }
            } else {
                scan_root(&path, depth + 1, visited, found);
            }
        }
    }
}
fn parse_skill(path: &Path, id: &str) -> Option<Skill> {
    if id.is_empty()
        || !id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    {
        return None;
    }
    if fs::metadata(path).ok()?.len() > MAX_BYTES {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    let (name, description, body) = parse_frontmatter(&text, id);
    if body.is_empty() {
        return None;
    }
    Some(Skill { id: id.into(), name, description, body, path: fs::canonicalize(path).ok()? })
}
fn parse_frontmatter(text: &str, id: &str) -> (String, String, String) {
    let mut name = id.to_owned();
    let mut desc = String::new();
    let mut body = text;
    let mut lines = text.split_inclusive('\n');
    if let Some(first) = lines.next()
        && first.trim() == "---"
    {
        let mut offset = first.len();
        let mut folded = false;
        for line in lines {
            offset += line.len();
            if line.trim() == "---" {
                body = &text[offset..];
                break;
            }
            let raw = line.trim();
            if let Some(v) = raw.strip_prefix("name:") {
                name = v.trim().trim_matches(['"', '\'']).to_owned();
                folded = false;
            } else if let Some(v) = raw.strip_prefix("description:") {
                let v = v.trim();
                folded = v.starts_with(['>', '|']);
                if !folded {
                    desc = v.trim_matches(['"', '\'']).to_owned();
                }
            } else if folded && line.starts_with([' ', '\t']) {
                if !desc.is_empty() {
                    desc.push(' ');
                }
                desc.push_str(raw);
            } else {
                folded = false;
            }
        }
    }
    (name, desc, body.trim().to_owned())
}
fn references(text: &str, prefix: &str) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let Some(trigger) = prefix.chars().next() else { return vec![] };
    let mut out = Vec::new();
    let mut i = 0;
    let mut code = false;
    while i < chars.len() {
        if chars[i] == '`' {
            code = !code;
            i += 1;
            continue;
        }
        let boundary =
            i == 0 || chars[i - 1].is_whitespace() || matches!(chars[i - 1], '(' | '[' | '{');
        if !code && boundary && chars[i] == trigger {
            let start = i + 1;
            let mut end = start;
            while end < chars.len()
                && (chars[end].is_ascii_alphanumeric() || matches!(chars[end], '-' | '_' | '.'))
            {
                end += 1;
            }
            let id: String = chars[start..end].iter().collect();
            let id = id.trim_end_matches('.').to_owned();
            // Shell variables and path references remain literal.
            if !id.is_empty()
                && !id.chars().all(|c| c.is_ascii_uppercase() || c == '_' || c.is_ascii_digit())
                && chars.get(end) != Some(&'/')
                && !out.contains(&id)
            {
                out.push(id);
            }
            i = end;
        } else {
            i += 1;
        }
    }
    out
}
/// Preserve the user's compact invocation and attach the selected skill body,
/// origin, and base directory. No shell expansion or skill execution occurs.
pub fn expand(text: &str, skills: &[Skill], prefix: &str) -> Result<String> {
    let ids = references(text, prefix);
    let mut out = text.to_owned();
    for id in ids {
        let Some(s) = skills.iter().find(|s| s.id == id) else { continue };
        let content = fs::read_to_string(&s.path)?;
        anyhow::ensure!(content.len() as u64 <= MAX_BYTES, "Skill {id} is too large");
        let (_, _, body) = parse_frontmatter(&content, &id);
        out.push_str(&format!("\n\n<skill name=\"{}\">\nSource: {}\nBase directory: {}\nResolve relative scripts and references against this base directory.\n\n{}\n</skill>", id, s.path.display(), s.path.parent().unwrap().display(), body));
    }
    Ok(out)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_crlf_frontmatter_and_folded_description() {
        let (n, d, b) = parse_frontmatter(
            "---\r\nname: 'réview'\r\ndescription: >\r\n  Check code\r\n  and tests\r\n---\r\nBody é",
            "review",
        );
        assert_eq!((n, d, b), ("réview".into(), "Check code and tests".into(), "Body é".into()));
        assert_eq!(parse_frontmatter("---\nname: hi\n---\nBody", "hi").2, "Body");
    }
    #[test]
    fn references_ignore_shell_code_and_partial_paths() {
        assert_eq!(
            references(
                "Use $review twice $review with $HOME and `$review` \\$review $review/file",
                "$"
            ),
            vec!["review"]
        );
        assert_eq!(references("Use %review", "%"), vec!["review"]);
    }
    #[test]
    fn nearest_project_wins_and_expansion_has_base_directory() {
        let root = std::env::temp_dir().join(format!("acpmux-skills-{}", uuid::Uuid::now_v7()));
        let home = root.join("home");
        let repo = root.join("repo");
        let cwd = repo.join("src");
        fs::create_dir_all(repo.join(".git")).unwrap();
        fs::create_dir_all(&cwd).unwrap();
        for (dir, body) in [
            (home.join(".agents/skills/review"), "global"),
            (repo.join(".opencode/skills/review"), "project"),
        ] {
            fs::create_dir_all(&dir).unwrap();
            fs::write(
                dir.join("SKILL.md"),
                format!("---\nname: Review\ndescription: Code review\n---\n{body}"),
            )
            .unwrap();
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(
            repo.join(".opencode/skills"),
            repo.join(".opencode/skills/loop"),
        )
        .unwrap();
        let all = discover_with_home(&cwd, &home, &[]);
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].body, "project");
        let expanded = expand("use $review carefully", &all, "$").unwrap();
        assert!(expanded.starts_with("use $review carefully"));
        assert!(expanded.contains("Base directory:"));
        assert!(expanded.contains("project"));
        fs::remove_dir_all(root).unwrap();
    }
}
