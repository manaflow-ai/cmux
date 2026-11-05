//! The cross-harness fallback for a folder's agent instructions.
//!
//! Each harness reads its own instruction file from the session folder: Claude
//! `CLAUDE.md`, Codex `AGENTS.md`, Gemini `GEMINI.md`. A folder set up for one
//! harness is opened with another all the time (a Codex repository in a Claude
//! chat), and that agent then never sees what the folder says about itself
//! (Leo, 2026-11-05: "you should be able to see all that and then be able to do
//! stuff based off that").
//!
//! When the session's harness has none of its own files in the folder, the first
//! other instruction file found ([`CANDIDATES`], `AGENTS.md` first) goes to the
//! session as one more first-turn context part, on the same user-context channel
//! and exactly once, like cmux's own guidance (`context_inventory::append_snapshot`).
//! A harness that has its own file gets nothing: it already reads it. The text is
//! the folder's own, which the harness would have read had it been named for it,
//! so this widens nothing a native file could not already do.

use std::path::Path;

use crate::context_inventory::{ContextPart, estimated_tokens};

/// The part's `source`; `append_snapshot` delivers it.
pub const SOURCE: &str = "cmux-folder";

/// The most of a file that goes to the agent; the rest is cut with a note.
const MAX_BYTES: usize = 32 * 1024;

/// The files a folder may carry instructions in, in the order the fallback
/// takes them: `AGENTS.md` is the cross-harness convention, the others are one
/// harness's or editor's own.
const CANDIDATES: &[&str] =
    &["AGENTS.md", "CLAUDE.md", "GEMINI.md", ".github/copilot-instructions.md", ".cursorrules"];

/// The files a harness family reads itself from the session folder. A family
/// not listed reads none, so any candidate is carried to it.
fn native(family: &str) -> &'static [&'static str] {
    match family {
        "claude" => &["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"],
        "codex" => &["AGENTS.md", "AGENTS.override.md"],
        "gemini" => &["GEMINI.md"],
        // opencode reads AGENTS.md, and CLAUDE.md when there is none.
        "opencode" => &["AGENTS.md", "CLAUDE.md"],
        _ => &[],
    }
}

/// The start of a regular file (at most the cap and a few bytes) and its full size.
fn readable(path: &Path) -> Option<(String, u64)> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    // A regular file only: never a link out of the folder, a fifo or a device.
    if !meta.file_type().is_file() {
        return None;
    }
    // Never more than the cap and a little: a huge file must not fill memory.
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(
        &mut std::io::Read::take(std::fs::File::open(path).ok()?, MAX_BYTES as u64 + 4),
        &mut bytes,
    )
    .ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    (!text.trim().is_empty()).then_some((text, meta.len()))
}

/// `parts` with the folder part for `cwd` in place of any earlier one: a fork
/// into another folder carries that folder's instructions, not its parent's.
pub fn retarget(mut parts: Vec<ContextPart>, family: &str, cwd: &Path) -> Vec<ContextPart> {
    parts.retain(|p| p.source != SOURCE);
    parts.extend(part(family, cwd));
    parts
}

/// The fallback part for a session of `family` in `cwd`, or `None` when the
/// harness reads its own file there or the folder carries no instructions.
pub fn part(family: &str, cwd: &Path) -> Option<ContextPart> {
    let own = native(family);
    if own.iter().any(|name| readable(&cwd.join(name)).is_some()) {
        return None;
    }
    let (name, text, bytes) = CANDIDATES
        .iter()
        .filter(|name| !own.contains(name))
        .find_map(|name| readable(&cwd.join(name)).map(|(text, bytes)| (*name, text, bytes)))?;
    let body = if text.len() > MAX_BYTES {
        let mut end = MAX_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        format!("{}\n\n[cut: {name} is {bytes} bytes; read the file for the rest]", &text[..end])
    } else {
        text
    };
    let text = format!(
        "This folder's {name} (instructions for agents working here; this harness does not read that file itself):\n\n{body}"
    );
    Some(ContextPart {
        id: format!("{SOURCE}-instructions"),
        source: SOURCE.into(),
        label: format!("Folder instructions ({name})"),
        tokens: estimated_tokens(&text),
        included: true,
        editable: false,
        measurement: "estimated".into(),
        source_bytes: Some(bytes),
        channel: Some("user-context".into()),
        text: Some(text),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(files: &[(&str, &str)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for (name, text) in files {
            let path = dir.path().join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        dir
    }

    #[test]
    fn claude_gets_agents_md_when_the_folder_has_no_claude_md() {
        let dir = folder(&[("AGENTS.md", "codeword KESTREL"), (".codex/config.toml", "")]);
        let got = part("claude", dir.path()).unwrap();
        assert_eq!(got.source, SOURCE);
        assert_eq!(got.label, "Folder instructions (AGENTS.md)");
        assert!(got.text.unwrap().contains("codeword KESTREL"));
    }

    #[test]
    fn a_harness_with_its_own_file_gets_nothing() {
        let dir = folder(&[("AGENTS.md", "a"), ("CLAUDE.md", "c")]);
        assert!(part("claude", dir.path()).is_none());
        assert!(part("codex", dir.path()).is_none());
        let dir = folder(&[(".claude/CLAUDE.md", "c"), ("AGENTS.md", "a")]);
        assert!(part("claude", dir.path()).is_none());
    }

    #[test]
    fn codex_and_gemini_get_another_harness_file() {
        let dir = folder(&[("CLAUDE.md", "from claude")]);
        assert!(part("codex", dir.path()).unwrap().text.unwrap().contains("from claude"));
        let dir = folder(&[(".cursorrules", "from cursor")]);
        let got = part("gemini", dir.path()).unwrap();
        assert_eq!(got.label, "Folder instructions (.cursorrules)");
        let dir = folder(&[(".github/copilot-instructions.md", "from vscode")]);
        assert!(part("claude", dir.path()).unwrap().text.unwrap().contains("from vscode"));
    }

    #[test]
    fn agents_md_wins_over_the_others_and_an_empty_folder_gets_nothing() {
        let dir = folder(&[("GEMINI.md", "g"), ("AGENTS.md", "a")]);
        assert_eq!(part("claude", dir.path()).unwrap().label, "Folder instructions (AGENTS.md)");
        assert!(part("claude", folder(&[]).path()).is_none());
        assert!(part("claude", folder(&[("AGENTS.md", "  \n")]).path()).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn a_link_is_never_followed() {
        let outside = folder(&[("secret.md", "outside")]);
        let dir = folder(&[]);
        std::os::unix::fs::symlink(outside.path().join("secret.md"), dir.path().join("AGENTS.md"))
            .unwrap();
        assert!(part("claude", dir.path()).is_none());
    }

    #[test]
    fn a_claude_sessions_first_turn_carries_the_folders_agents_md_once_captured() {
        let dir = folder(&[("AGENTS.md", "codeword KESTREL")]);
        let meta: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": "acpmux.session.v1", "id": "s", "name": "s", "harness": "claude",
            "cwd": dir.path(), "status": "idle", "createdAt": 0, "updatedAt": 0,
        }))
        .unwrap();
        let parts =
            crate::context_inventory::snapshot_session(&meta, &crate::config::Config::default());
        // The file changing after the session began changes nothing it was given.
        std::fs::write(dir.path().join("AGENTS.md"), "later").unwrap();
        let mut blocks = Vec::new();
        crate::context_inventory::append_snapshot(Some(&parts), &mut blocks);
        let text: Vec<&str> = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
        let folder = text.iter().find(|t| t.starts_with("<cmux-folder-context>")).unwrap();
        assert!(folder.contains("codeword KESTREL"));
        assert!(!folder.contains("later"));
    }

    #[test]
    fn a_huge_file_is_read_only_up_to_the_cap() {
        let dir = folder(&[]);
        let file = std::fs::File::create(dir.path().join("AGENTS.md")).unwrap();
        file.set_len(1 << 30).unwrap();
        // A sparse 1 GiB file of zeros: read whole, the test would take a gigabyte.
        let got = part("claude", dir.path()).unwrap();
        assert_eq!(got.source_bytes, Some(1 << 30));
        assert!(got.text.unwrap().len() < 2 * MAX_BYTES);
    }

    #[test]
    fn a_claude_code_profile_of_its_own_family_reads_claude_md() {
        let mut cfg = crate::config::Config::default();
        cfg.harnesses.insert(
            "claude-sr2".into(),
            serde_json::from_value(serde_json::json!({
                "kind": "claude-stdio", "argv": ["sr2"], "family": "claude-sr2",
            }))
            .unwrap(),
        );
        let family = crate::context_inventory::family_for_folder(&cfg, "claude-sr2");
        assert_eq!(family, "claude");
        let dir = folder(&[("CLAUDE.md", "c"), ("AGENTS.md", "a")]);
        assert!(part(&family, dir.path()).is_none());
    }

    #[test]
    fn a_fork_into_another_folder_carries_that_folders_instructions() {
        let parent = folder(&[("AGENTS.md", "parent words")]);
        let child = folder(&[("GEMINI.md", "child words")]);
        let parts =
            retarget(part("claude", parent.path()).into_iter().collect(), "claude", child.path());
        assert_eq!(parts.len(), 1);
        assert!(parts[0].text.as_deref().unwrap().contains("child words"));
        let none = retarget(parts, "claude", folder(&[]).path());
        assert!(none.is_empty());
    }

    #[test]
    fn a_long_file_is_cut_on_a_character_boundary() {
        let long = "é".repeat(MAX_BYTES);
        let dir = folder(&[("AGENTS.md", &long)]);
        let text = part("claude", dir.path()).unwrap().text.unwrap();
        assert!(text.contains("[cut: AGENTS.md is"));
        assert!(text.len() < long.len());
    }
}
