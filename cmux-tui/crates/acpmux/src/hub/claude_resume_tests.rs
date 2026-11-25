//! `claude_resume_refusal`: `--resume <id>` goes out only for a conversation the
//! store this profile reads still holds.
//!
//! Red on the base: the store was checked only when another profile had run the
//! chat, so a conversation gone from the profile's own store (the Chief
//! compactor deletes a transcript it folded; a pruned or deleted store loses the
//! rest) was resumed anyway, and every turn of that session failed forever with
//! `No conversation found with session ID`.

use super::claude_resume_refusal;
use serde_json::json;
use std::path::{Path, PathBuf};

const CHAT: &str = "0199a1b2-0000-7000-8000-00000000c1a0";

fn home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("acpmux-claude-resume-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    home
}

/// A Claude profile reading the store at `root`.
fn profile(root: &Path) -> crate::config::HarnessProfile {
    serde_json::from_value(json!({
        "kind": "claude-stdio", "argv": ["claude"],
        "env": {"CLAUDE_CONFIG_DIR": root},
    }))
    .unwrap()
}

/// A chat whose last turn ran on `claude_profile`, in `cwd`, holding `CHAT`.
fn meta(cwd: &Path, claude_profile: &str) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s1", "name": "s1",
        "harness": "claude", "family": "claude", "cwd": cwd, "status": "idle",
        "createdAt": 1, "updatedAt": 1, "agentSessionId": CHAT,
        "claudeProfile": claude_profile,
    }))
    .unwrap()
}

/// Write `CHAT`'s transcript into the folder Claude names for `cwd`.
fn write_transcript(root: &Path, cwd: &Path) {
    let dir = root.join("projects").join(crate::adopt::project_dir_name(cwd));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(format!("{CHAT}.jsonl")), format!("{}\n", json!({"type": "user"})))
        .unwrap();
}

/// The store decides for the profile that ran the chat too, not only for another
/// one: a conversation the store no longer holds is refused, so the caller
/// starts a fresh one instead of passing `--resume` for a conversation Claude
/// cannot find.
#[test]
fn a_conversation_gone_from_its_own_profiles_store_is_refused() {
    let root = home("same-profile");
    let cwd = root.join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let profile = profile(&root);

    // Same profile, transcript deleted (what the compactor leaves behind).
    let gone = meta(&cwd, "claude");
    assert_eq!(
        claude_resume_refusal(&gone, &profile, CHAT),
        Some("is no longer in Claude's store"),
        "a missing conversation must be refused even when this profile ran it"
    );

    // The same chat resumes once its transcript is there.
    write_transcript(&root, &cwd);
    assert_eq!(claude_resume_refusal(&gone, &profile, CHAT), None);

    // Another profile's chat still names that store in its reason.
    let elsewhere = meta(&cwd, "claude-sr2");
    assert_eq!(claude_resume_refusal(&elsewhere, &profile, CHAT), None);
    std::fs::remove_file(
        root.join("projects")
            .join(crate::adopt::project_dir_name(&cwd))
            .join(format!("{CHAT}.jsonl")),
    )
    .unwrap();
    assert_eq!(
        claude_resume_refusal(&elsewhere, &profile, CHAT),
        Some("is not in this profile's Claude store")
    );

    // A chat that never finished a turn is refused before any store read.
    let mut unstored = meta(&cwd, "claude");
    unstored.claude_unstored = true;
    assert_eq!(claude_resume_refusal(&unstored, &profile, CHAT), Some("never finished a turn"));

    let _ = std::fs::remove_dir_all(root);
}

/// The store read finds the transcript in the folder `cwd` names without
/// reading the other project folders (1411 of them on a busy host).
#[test]
fn the_store_read_is_scoped_to_the_chats_project_folder() {
    let root = home("scoped");
    let cwd = root.join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    write_transcript(&root, &cwd);
    let projects = root.join("projects");
    for n in 0..4 {
        std::fs::create_dir_all(projects.join(format!("-other-{n}"))).unwrap();
    }

    // A cwd that names no folder of its own falls back to the full walk, which
    // still finds it.
    assert!(crate::adopt::claude_session_exists_near(&root, CHAT, Path::new("/elsewhere")));
    // An id the store does not have is missing either way.
    let absent = "0199a1b2-0000-7000-8000-00000000dead";
    assert!(!crate::adopt::claude_session_exists_near(&root, absent, &cwd));
    // Not a bare id: never a path from a request.
    assert!(!crate::adopt::claude_session_exists_near(&root, "../escape", &cwd));
    assert_eq!(crate::adopt::project_dir_name(Path::new("/Users/me/fun")), "-Users-me-fun");

    // `projects/` can be walked through but not listed (mode 0o300): the folder
    // `cwd` names is still read, a walk of every folder under it is not. The
    // full scan is what the old check cost on every resume.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&projects, std::fs::Permissions::from_mode(0o300)).unwrap();
        assert!(
            crate::adopt::find_claude(&root, CHAT).is_none(),
            "a walk needs to list projects/, so this proves the scoped read did not walk"
        );
        assert!(crate::adopt::claude_session_exists_near(&root, CHAT, &cwd));
        std::fs::set_permissions(&projects, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let _ = std::fs::remove_dir_all(root);
}
