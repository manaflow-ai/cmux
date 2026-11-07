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
/// and folder.
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
