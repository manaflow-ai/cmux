//! A moved chat carries its agent's own store (`native.rs`), so the agent resumes with its whole
//! context on the target machine, whatever profile started it: Claude Code's project file,
//! Codex's rollout, pi's session file, OpenCode's exported session.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts here: the stores are files the tests write.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::native;
use acpmux::store::SessionMeta;
use serde_json::json;
use std::path::{Path, PathBuf};

fn meta(harness: &str, family: &str, sid: &str, cwd: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": "acpmux.session.v1",
        "id": "01a1a0d0-0000-7000-8000-000000000001",
        "name": "teleport",
        "harness": harness,
        "family": family,
        "cwd": cwd,
        "status": "ready",
        "createdAt": 1,
        "updatedAt": 1,
        "agentSessionId": sid,
    }))
    .unwrap()
}

fn put(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn labels(found: &[(String, PathBuf)]) -> Vec<&str> {
    found.iter().map(|(l, _)| l.as_str()).collect()
}

#[test]
fn claude_profile_variant_carries_its_project_file() {
    let home = tempfile::tempdir().unwrap();
    let sid = "4b3c2d1e-aaaa-bbbb-cccc-111122223333";
    put(&home.path().join(".claude/projects/-src/").join(format!("{sid}.jsonl")), "{}\n");
    let found = native::locate_in(&meta("claude-sr", "claude", sid, "/src"), home.path());
    assert_eq!(labels(&found), ["claude-project"]);
}

#[test]
fn claude_subagent_transcripts_travel_beside_the_project_file() {
    let src_home = tempfile::tempdir().unwrap();
    let sid = "4b3c2d1e-aaaa-bbbb-cccc-111122223333";
    let dir = src_home.path().join(".claude/projects/-src");
    put(&dir.join(format!("{sid}.jsonl")), "{\"type\":\"user\"}\n");
    put(&dir.join(sid).join("subagents/agent-a1.jsonl"), "{\"agentId\":\"a1\"}\n");
    // Another session's children stay behind.
    put(&dir.join("other-session/subagents/agent-b1.jsonl"), "{}\n");
    let here = meta("claude", "claude", sid, "/src");
    let found = native::locate_in(&here, src_home.path());
    let mut found_labels = labels(&found);
    found_labels.sort();
    assert_eq!(found_labels, ["claude-project", "claude-subagent"]);

    let bundle = tempfile::tempdir().unwrap();
    for (label, src) in &found {
        native::copy_into_from(src, &bundle.path().join("native"), label, src_home.path()).unwrap();
    }
    let dst_home = tempfile::tempdir().unwrap();
    let there = meta("claude", "claude", sid, "/elsewhere/dst");
    assert_eq!(native::restore_in(bundle.path(), &there, dst_home.path()).unwrap(), 2);
    let moved = dst_home.path().join(".claude/projects/-elsewhere-dst");
    assert_eq!(
        std::fs::read_to_string(moved.join(sid).join("subagents/agent-a1.jsonl")).unwrap(),
        "{\"agentId\":\"a1\"}\n"
    );
    assert!(moved.join(format!("{sid}.jsonl")).exists());
}

#[test]
fn codex_acp_profile_carries_its_rollout() {
    let home = tempfile::tempdir().unwrap();
    let sid = "019a3c2e-7f41-7a2b-9c3d-5e6f7a8b9c0d";
    put(
        &home
            .path()
            .join(".codex/sessions/2026/11/03")
            .join(format!("rollout-2026-11-03T01-02-03-{sid}.jsonl")),
        "{}\n",
    );
    let found = native::locate_in(&meta("codex-acp", "codex", sid, "/src"), home.path());
    assert_eq!(labels(&found), ["codex-rollout"]);
}

#[test]
fn pi_session_moves_into_the_target_folders_session_dir() {
    let src_home = tempfile::tempdir().unwrap();
    let sid = "019fcb7d-55a8-7460-8eca-b390f5652268";
    let file = format!("2026-08-04T06-36-56-616Z_{sid}.jsonl");
    put(
        &src_home.path().join(".pi/agent/sessions/--Users-me-src--").join(&file),
        &format!("{{\"type\":\"session\",\"id\":\"{sid}\",\"cwd\":\"/Users/me/src\"}}\n"),
    );
    // Another session's file in the same folder stays behind.
    put(&src_home.path().join(".pi/agent/sessions/--Users-me-src--/other_x.jsonl"), "{}\n");
    let here = meta("pi", "pi", sid, "/Users/me/src");
    let found = native::locate_in(&here, src_home.path());
    assert_eq!(labels(&found), ["pi-session"]);

    let bundle = tempfile::tempdir().unwrap();
    for (label, src) in &found {
        native::copy_into_from(src, &bundle.path().join("native"), label, src_home.path()).unwrap();
    }
    let dst_home = tempfile::tempdir().unwrap();
    let there = meta("pi", "pi", sid, "/home/cmux/work/src");
    assert_eq!(native::restore_in(bundle.path(), &there, dst_home.path()).unwrap(), 1);
    assert!(
        dst_home.path().join(".pi/agent/sessions/--home-cmux-work-src--").join(&file).is_file()
    );

    // A guarded move (Move to Cloud) takes it too, into the same place.
    let plan = native::guarded_plan(bundle.path(), &there).unwrap();
    assert_eq!(plan.len(), 1);
    assert_eq!(plan[0].1, Path::new(".pi/agent/sessions/--home-cmux-work-src--").join(&file));
}

/// A stand-in `opencode` CLI: `export ID` prints a session, `import FILE` records its argument
/// and folder. A `/bin/sh` script, so Unix only.
#[cfg(unix)]
fn fake_opencode(dir: &Path, exported_id: &str) -> PathBuf {
    let cli = dir.join("opencode");
    let log = dir.join("import.log");
    std::fs::write(
        &cli,
        format!(
            "#!/bin/sh\ncase \"$1\" in\n export) echo 'Exporting session' >&2; printf '{{\"info\":{{\"id\":\"{exported_id}\",\"directory\":\"/src\"}},\"messages\":[]}}\\n';;\n import) printf '%s\\n%s\\n' \"$2\" \"$(pwd -P)\" > '{}'; echo \"Imported session: x\";;\n *) exit 2;;\nesac\n",
            log.display()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    cli
}

#[cfg(unix)]
#[test]
fn opencode_session_is_exported_and_imported_in_the_target_folder() {
    let tools = tempfile::tempdir().unwrap();
    let sid = "ses_e5f2f32dcffeXJMADboErwFyEF";
    let cli = fake_opencode(tools.path(), sid);
    let bundle = tempfile::tempdir().unwrap();
    let here = meta("opencode", "opencode", sid, "/src");
    let rel = native::export_opencode_with(&cli, &here, &bundle.path().join("native")).unwrap();
    assert_eq!(rel.as_deref(), Some(format!("opencode-export/{sid}.json").as_str()));

    let target = tempfile::tempdir().unwrap();
    let there = meta("opencode-v2", "opencode", sid, target.path().to_str().unwrap());
    assert!(native::import_opencode_with(&cli, bundle.path(), &there).unwrap());
    let log = std::fs::read_to_string(tools.path().join("import.log")).unwrap();
    let mut lines = log.lines();
    assert!(lines.next().unwrap().ends_with(&format!("{sid}.json")));
    assert_eq!(Path::new(lines.next().unwrap()), std::fs::canonicalize(target.path()).unwrap());
    // The bundle's export is not a home file: a guarded move neither refuses it nor copies it.
    assert!(native::guarded_plan(bundle.path(), &there).unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn opencode_export_of_another_session_is_refused() {
    let tools = tempfile::tempdir().unwrap();
    let cli = fake_opencode(tools.path(), "ses_someoneElse000000000000");
    let bundle = tempfile::tempdir().unwrap();
    let here = meta("opencode", "opencode", "ses_e5f2f32dcffeXJMADboErwFyEF", "/src");
    assert!(native::export_opencode_with(&cli, &here, &bundle.path().join("native")).is_err());
    assert!(!bundle.path().join("native/opencode-export").exists());
}

/// A chat that comes back to a machine it ran on finds that machine's old copy of its transcript
/// there: the copy the move took grew elsewhere. The bundle's copy replaces an old copy that is a
/// prefix of it (the same append-only log, shorter); a copy that is not is kept.
#[test]
fn a_chat_coming_back_replaces_its_stale_transcript_but_never_a_diverged_one() {
    let sid = "4b3c2d1e-aaaa-bbbb-cccc-111122223333";
    let here = meta("claude", "claude", sid, "/Users/me/src");
    let rel = Path::new(".claude/projects/-Users-me-src").join(format!("{sid}.jsonl"));
    let bundle = tempfile::tempdir().unwrap();
    put(
        &bundle.path().join("native/claude-project").join(&rel),
        "{\"turn\":1}\n{\"turn\":2,\"on\":\"vm\"}\n",
    );

    let home = tempfile::tempdir().unwrap();
    put(&home.path().join(&rel), "{\"turn\":1}\n");
    assert_eq!(native::restore_in(bundle.path(), &here, home.path()).unwrap(), 1);
    assert_eq!(
        std::fs::read_to_string(home.path().join(&rel)).unwrap(),
        "{\"turn\":1}\n{\"turn\":2,\"on\":\"vm\"}\n"
    );

    let other = tempfile::tempdir().unwrap();
    put(&other.path().join(&rel), "{\"turn\":1}\n{\"turn\":2,\"on\":\"here\"}\n");
    assert_eq!(native::restore_in(bundle.path(), &here, other.path()).unwrap(), 0);
    assert_eq!(
        std::fs::read_to_string(other.path().join(&rel)).unwrap(),
        "{\"turn\":1}\n{\"turn\":2,\"on\":\"here\"}\n"
    );
}

/// An Auto chat's Cloud copy is the chat: its transcript replaces one here that went another
/// way, and what was here is kept beside it. The same bytes are left alone.
#[test]
fn a_cloud_copy_replaces_a_diverged_transcript_and_keeps_what_was_there() {
    let sid = "4b3c2d1e-aaaa-bbbb-cccc-111122223333";
    let here = meta("claude", "claude", sid, "/Users/me/src");
    let rel = Path::new(".claude/projects/-Users-me-src").join(format!("{sid}.jsonl"));
    let copy = "{\"turn\":1}\n{\"turn\":2,\"on\":\"vm\"}\n";
    let bundle = tempfile::tempdir().unwrap();
    put(&bundle.path().join("native/claude-project").join(&rel), copy);

    let home = tempfile::tempdir().unwrap();
    let mine = "{\"turn\":1}\n{\"turn\":2,\"on\":\"here\"}\n";
    put(&home.path().join(&rel), mine);
    assert_eq!(native::restore_replacing_in(bundle.path(), &here, home.path()).unwrap(), 1);
    assert_eq!(std::fs::read_to_string(home.path().join(&rel)).unwrap(), copy);
    let kept = home
        .path()
        .join(".claude/projects/-Users-me-src")
        .join(format!("{sid}.jsonl{}", native::REPLACED_SUFFIX));
    assert_eq!(std::fs::read_to_string(&kept).unwrap(), mine);
    // What is kept is no session of the chat's: the next copy does not carry it.
    let found = native::locate_in(&here, home.path());
    assert_eq!(found, [("claude-project".to_owned(), home.path().join(&rel))]);

    // The same copy again changes nothing.
    assert_eq!(native::restore_replacing_in(bundle.path(), &here, home.path()).unwrap(), 0);
    assert_eq!(std::fs::read_to_string(&kept).unwrap(), mine);
}

/// A chat that ran in another folder of this machine before left a file of its conversation
/// under that folder's name. The one under the chat's own folder is the one that goes.
#[test]
fn a_claude_chat_carries_the_file_of_its_own_folder() {
    let home = tempfile::tempdir().unwrap();
    let sid = "4b3c2d1e-aaaa-bbbb-cccc-111122223333";
    let name = format!("{sid}.jsonl");
    put(&home.path().join(".claude/projects/-Users-me-old").join(&name), "{\"old\":1}\n");
    let own = home.path().join(".claude/projects/-Users-me-src").join(&name);
    put(&own, "{\"turn\":1}\n");
    let found = native::locate_in(&meta("claude", "claude", sid, "/Users/me/src"), home.path());
    assert_eq!(found, [("claude-project".to_owned(), own)]);
}

/// A history-later move's bundle takes the prepare's copy of the agent's transcript and only
/// what the file grew by since (`grow_into_from`), cut back to its last whole line; a file that
/// is not that copy grown at its end is left to the whole copy (None). Its restore links the
/// bundle's file in, the same bytes.
#[test]
fn a_prepared_transcript_moves_with_only_its_growth() {
    let sid = "4b3c2d1e-aaaa-bbbb-cccc-111122223333";
    let rel = Path::new(".claude/projects/-Users-me-src").join(format!("{sid}.jsonl"));
    let home = tempfile::tempdir().unwrap();
    let src = home.path().join(&rel);
    let early = "{\"turn\":1}\n".repeat(20_000);
    put(&src, &early);
    let prepared = tempfile::tempdir().unwrap();
    native::copy_into_from(&src, prepared.path(), "claude-project", home.path()).unwrap();

    let grown = format!("{early}{{\"turn\":2}}\n{{\"turn\":3,\"half");
    put(&src, &grown);
    let bundle = tempfile::tempdir().unwrap();
    let dest = bundle.path().join("native");
    let moved = native::grow_into_from(&src, prepared.path(), &dest, "claude-project", home.path());
    let moved = moved.unwrap().expect("the grown file takes the prepared copy");
    assert_eq!(moved, Path::new("claude-project").join(&rel).to_string_lossy());
    let copy = std::fs::read_to_string(dest.join(&moved)).unwrap();
    assert_eq!(copy, format!("{early}{{\"turn\":2}}\n"));
    assert!(!prepared.path().join("claude-project").join(&rel).exists(), "moved, not copied");

    let there = meta("claude", "claude", sid, "/Users/me/src");
    let target = tempfile::tempdir().unwrap();
    assert_eq!(native::restore_in_with(bundle.path(), &there, target.path(), true).unwrap(), 1);
    assert_eq!(std::fs::read_to_string(target.path().join(&rel)).unwrap(), copy);

    // Rewritten before the copy's end, or shorter: the whole copy goes instead.
    let again = tempfile::tempdir().unwrap();
    put(&src, &early);
    native::copy_into_from(&src, again.path(), "claude-project", home.path()).unwrap();
    put(&src, &format!("{}{{\"turn\":9}}\n", "{\"turn\":0}\n".repeat(20_000)));
    let other = tempfile::tempdir().unwrap();
    let refused =
        native::grow_into_from(&src, again.path(), other.path(), "claude-project", home.path());
    assert!(refused.unwrap().is_none());
    put(&src, "{\"turn\":1}\n");
    let refused =
        native::grow_into_from(&src, again.path(), other.path(), "claude-project", home.path());
    assert!(refused.unwrap().is_none());
}
