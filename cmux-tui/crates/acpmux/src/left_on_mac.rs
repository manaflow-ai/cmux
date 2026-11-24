//! What a Cloud chat's partial copy left on the person's Mac, told to the chat's agent.
//!
//! A chat started in Cloud from a folder past what a copy sends whole (Leo's `~/Projects`) gets a
//! first pass of it (cmux-tui `link/sync_cli/size_cap.rs`): the smallest files, no repository
//! history. The copy writes [`NOTE`] at the top of the folder on the machine, naming what stayed on
//! the Mac (folders and the largest files, with sizes, summarized when long) and how to get one
//! (`cmux link access request PATH`). Without it the agent went looking for those files, or took
//! them for missing (cmuxterm-hq#11697, item 2).
//!
//! The note goes to the session as one more first-turn context part, on the same user-context
//! channel and exactly once, like a folder's instructions ([`crate::folder_instructions`]). A chat
//! may open below the copy's top (a folder inside a repository that was copied whole), so the
//! session folder and the folders above it are looked in, nearest first. Each is opened without
//! following a link at any step. The name starts with `.cmux-sync`, which no pull brings back to
//! the Mac and no share sends.

use std::path::Path;

use crate::context_inventory::{ContextPart, estimated_tokens};

/// The note's name at the top of a partial copy on the machine. The copy writes it
/// (cmux-tui `sync_cli`), and this reads it: one name for both.
pub const NOTE: &str = ".cmux-sync-left-on-mac.md";

/// The part's `source`; `context_inventory::append_snapshot` delivers it.
pub const SOURCE: &str = "cmux-left-on-mac";

/// The most folders above the session folder looked in for the note.
const MAX_UP: usize = 32;

/// The note of the partial copy `cwd` is in, as a context part: none when `cwd` is in no partial
/// copy (a folder copied whole, a Mac folder, a copy made before the note existed).
pub fn part(cwd: &Path) -> Option<ContextPart> {
    let (folder, text, bytes) = cwd.ancestors().take(MAX_UP + 1).find_map(|folder| {
        crate::folder_instructions::readable(folder, NOTE)
            .map(|(text, bytes)| (folder, text, bytes))
    })?;
    let text = format!(
        "This folder is a partial copy of a folder on the person's Mac. The note {} lists what stayed on the Mac: those files exist there, they are not missing. Ask for one with `cmux link access request PATH` (its path on the Mac), or ask the person; do not search this machine for them.\n\n{text}",
        folder.join(NOTE).display()
    );
    Some(ContextPart {
        id: SOURCE.into(),
        source: SOURCE.into(),
        label: "What stayed on the Mac".into(),
        tokens: estimated_tokens(&text),
        included: true,
        editable: false,
        measurement: "estimated".into(),
        source_bytes: Some(bytes),
        channel: Some(crate::context_inventory::USER_CONTEXT.into()),
        text: Some(text.into()),
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_session_in_a_partial_copy_or_below_its_top_is_told_what_stayed_on_the_mac() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join(NOTE), "- `Downloads/`: 1 file, 21.0 GB\n").unwrap();
        std::fs::create_dir_all(root.path().join("cmux/src")).unwrap();
        for cwd in [root.path().to_path_buf(), root.path().join("cmux/src")] {
            let part = part(&cwd).expect("the note is found");
            let text = part.text.unwrap();
            assert!(text.contains("Downloads/") && text.contains("21.0 GB"), "{text}");
            assert!(text.contains("cmux link access request"), "{text}");
            assert_eq!(part.channel.as_deref(), Some(crate::context_inventory::USER_CONTEXT));
        }
        let mut blocks = Vec::new();
        crate::context_inventory::append_snapshot(Some(&[part(root.path()).unwrap()]), &mut blocks);
        assert_eq!(blocks.len(), 1, "the note goes with the first message");
        assert!(blocks[0]["text"].as_str().unwrap().contains("<cmux-left-on-mac-context>"));
    }

    #[test]
    fn a_folder_copied_whole_gets_no_note() {
        let root = tempfile::tempdir().unwrap();
        assert!(part(root.path()).is_none());
        // An empty note says nothing.
        std::fs::write(root.path().join(NOTE), "  \n").unwrap();
        assert!(part(root.path()).is_none());
    }
}
