use std::os::unix::fs::symlink;
use std::path::Path;

use super::*;

fn put(home: &Path, relative: &str, text: &str) {
    let path = home.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn none() -> Sources {
    Sources { folders: Vec::new(), ledger: None }
}

fn carried(plan: &Plan) -> Vec<&str> {
    plan.manifest.iter().map(|entry| entry.path.as_str()).collect()
}

fn reason<'a>(plan: &'a Plan, path: &str) -> Option<&'a str> {
    plan.refused.iter().find(|refused| refused.path == path).map(|refused| refused.reason.as_str())
}

/// A git checkout at `folder` whose origin is `remote`.
fn checkout(folder: &Path, remote: &str) {
    std::fs::create_dir_all(folder.join(".git")).unwrap();
    std::fs::write(
        folder.join(".git").join("config"),
        format!("[remote \"origin\"]\n\turl = {remote}\n"),
    )
    .unwrap();
}

/// A transcript in `slug`'s folder that records `cwd`.
fn transcript(home: &Path, slug: &str, cwd: &str) {
    put(
        home,
        &format!(".claude/projects/{slug}/session-{}.jsonl", claude_slug(cwd)),
        &format!("{}\n", json!({"type": "user", "cwd": cwd})),
    );
}

#[test]
fn the_allowlist_is_carried_and_nothing_beside_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    for path in [
        ".claude/CLAUDE.md",
        ".codex/AGENTS.md",
        ".gemini/GEMINI.md",
        ".claude/agents/reviewer.md",
        ".claude/commands/ship/fast.md",
        ".claude/skills/x/SKILL.md",
        ".codex/prompts/fix.md",
    ] {
        put(home, path, "be kind\n");
    }
    put(home, ".claude/notes.md", "not on the allowlist\n");
    put(home, ".bashrc", "export X=1\n");
    let plan = plan(home, &none(), Caps::default()).unwrap();
    assert_eq!(
        carried(&plan),
        [
            ".claude/CLAUDE.md",
            ".claude/agents/reviewer.md",
            ".claude/commands/ship/fast.md",
            ".claude/skills/x/SKILL.md",
            ".codex/AGENTS.md",
            ".codex/prompts/fix.md",
            ".gemini/GEMINI.md",
        ]
    );
    assert_eq!(plan.total_bytes, 7 * 8);
    let entry = &plan.manifest[0];
    assert_eq!(entry.sha256, sha256_hex(b"be kind\n"));
    assert_eq!((entry.project.as_deref(), entry.bytes), (None, 8));
}

#[test]
fn every_never_carried_name_is_left_out_with_its_reason() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    for path in NEVER_CARRIED {
        put(home, path, "{}\n");
    }
    // Never-carried names inside allowlisted folders.
    let inside = [
        ".claude/skills/x/settings.json",
        ".claude/skills/x/settings.local.json",
        ".claude/skills/x/.env",
        ".claude/skills/x/.env.local",
        ".claude/agents/server.pem",
        ".claude/agents/server.key",
        ".claude/agents/cert.p12",
        ".claude/commands/.credentials.json",
        ".claude/commands/.git-credentials",
        ".claude/commands/client_secret.md",
        ".claude/commands/token.txt",
        ".codex/prompts/auth.json",
        ".codex/prompts/config.toml",
        ".codex/prompts/id_rsa",
        ".codex/prompts/id_ed25519",
        ".codex/prompts/id_ecdsa",
        ".codex/prompts/id_dsa",
        ".codex/prompts/.netrc",
        ".codex/prompts/.npmrc",
        ".codex/prompts/.pypirc",
        ".claude/skills/g/oauth_creds.json",
        ".claude/skills/h/history.jsonl",
        ".claude/skills/x/SKILL.md.cmux-sync-conflict",
    ];
    for path in inside {
        put(home, path, "harmless\n");
    }
    let plan = plan(home, &none(), Caps::default()).unwrap();
    assert!(plan.manifest.is_empty(), "{:?}", carried(&plan));
    for path in NEVER_CARRIED {
        assert_eq!(reason(&plan, path), Some("never carried"), "{path}");
    }
    for path in inside {
        let why = reason(&plan, path).unwrap_or_else(|| panic!("{path} not refused"));
        assert!(matches!(why, "credential name" | "sync side file"), "{path}: {why}");
    }
    // pull and propose refuse the same names: one check.
    for path in inside {
        assert!(!super::super::carried(path), "{path}");
    }
}

#[test]
fn a_secret_in_an_allowed_file_refuses_that_file_and_names_the_kind() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let secrets = [
        ("anthropic key", "key sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA"),
        ("openai key", "sk-proj-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
        ("github token", "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
        ("github token", "github_pat_11AAAAAAAAAAAAAAAAAAAAAAAAAA"),
        ("gitlab token", "glpat-AAAAAAAAAAAAAAAAAAAAAA"),
        ("slack token", "xoxb-1111111111-AAAAAAAAAAAA"),
        ("aws key", "AKIAABCDEFGHIJKLMNOP"),
        ("aws credentials", "[default]\naws_secret_access_key = abc\n"),
        ("private key", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n"),
        ("private key", "-----BEGIN RSA PRIVATE KEY-----\nabc\n"),
        ("jwt", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXNpZ24"),
        ("netrc", "machine api.example.com\n  login me\n  password hunter2\n"),
        ("credential json", "{\"refresh_token\": \"abc\"}"),
        ("credential json", "{\"type\": \"service_account\", \"private_key\": \"x\"}"),
    ];
    for (n, (_, text)) in secrets.iter().enumerate() {
        put(home, &format!(".claude/commands/s{n}.md"), &format!("# notes\n{text}\n"));
    }
    put(home, ".claude/CLAUDE.md", "talk about tokens and sk-ant- keys, never paste one\n");
    let plan = plan(home, &none(), Caps::default()).unwrap();
    assert_eq!(carried(&plan), [".claude/CLAUDE.md"]);
    for (n, (kind, _)) in secrets.iter().enumerate() {
        assert_eq!(
            reason(&plan, &format!(".claude/commands/s{n}.md")),
            Some(format!("secret: {kind}").as_str()),
            "{n}"
        );
    }
}

#[test]
fn binary_bytes_links_and_hard_links_are_never_carried() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let outside = tmp.path().join("outside");
    std::fs::create_dir_all(&home).unwrap();
    put(&outside, "secret.md", "the key\n");
    put(&home, ".claude/commands/ok.md", "fine\n");
    std::fs::write(home.join(".claude/commands/blob.md"), b"a\0b").unwrap();
    std::fs::write(home.join(".claude/commands/latin.md"), b"caf\xe9").unwrap();
    symlink(outside.join("secret.md"), home.join(".claude/commands/link.md")).unwrap();
    std::fs::hard_link(outside.join("secret.md"), home.join(".claude/commands/hard.md")).unwrap();
    symlink(&outside, home.join(".claude/agents")).unwrap();
    let plan = plan(&home, &none(), Caps::default()).unwrap();
    assert_eq!(carried(&plan), [".claude/commands/ok.md"]);
    assert_eq!(reason(&plan, ".claude/commands/blob.md"), Some("not text"));
    assert_eq!(reason(&plan, ".claude/commands/latin.md"), Some("not text"));
    assert_eq!(reason(&plan, ".claude/commands/hard.md"), Some("a hard link"));
    // A link is never walked into, so nothing under it is even listed.
    assert!(plan.refused.iter().all(|refused| !refused.path.starts_with(".claude/agents")));
}

#[test]
fn paths_not_in_plain_form_are_refused_never_cleaned() {
    for bad in [
        "/.claude/CLAUDE.md",
        ".claude/commands/../CLAUDE.md",
        ".claude/commands/./x.md",
        ".claude/commands//x.md",
        ".claude/commands/a\\b.md",
        ".claude/commands/bell\u{7}.md",
        ".claude/commands/cafe\u{301}.md",
    ] {
        assert_eq!(super::super::refusal(bad), Some("path form"), "{bad:?}");
    }
    let long = format!(".claude/commands/{}.md", "a".repeat(500));
    assert_eq!(super::super::refusal(&long), Some("path form"));
    assert_eq!(super::super::refusal(".claude/commands/caf\u{e9}.md"), None);
    // A non-NFC name on disk is listed as refused, not carried under its NFC spelling.
    let tmp = tempfile::tempdir().unwrap();
    put(tmp.path(), ".claude/commands/cafe\u{301}.md", "x\n");
    let plan = plan(tmp.path(), &none(), Caps::default()).unwrap();
    assert!(plan.manifest.is_empty());
    assert_eq!(reason(&plan, ".claude/commands/cafe\u{301}.md"), Some("path form"));
}

#[test]
fn the_size_caps_hold_per_file_per_person_and_per_entry_count() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    // The real file cap: one byte over 1 MiB is refused, exactly 1 MiB is carried.
    put(home, ".claude/commands/big.md", &"a".repeat(FILE_MAX as usize + 1));
    put(home, ".claude/commands/edge.md", &"a".repeat(FILE_MAX as usize));
    let plan = plan(home, &none(), Caps::default()).unwrap();
    assert_eq!(carried(&plan), [".claude/commands/edge.md"]);
    assert_eq!(reason(&plan, ".claude/commands/big.md"), Some("over the file cap (1048576 bytes)"));
    assert_eq!(Caps::default().total_bytes, 16 * 1024 * 1024);
    assert_eq!(Caps::default().entries, 2_000);

    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    for n in 0..5 {
        put(home, &format!(".claude/commands/{n}.md"), "0123456789");
    }
    let caps = Caps { total_bytes: 25, ..Caps::default() };
    let by_bytes = plan(home, &none(), caps).unwrap();
    assert_eq!(carried(&by_bytes), [".claude/commands/0.md", ".claude/commands/1.md"]);
    assert_eq!(by_bytes.total_bytes, 20);
    assert_eq!(
        reason(&by_bytes, ".claude/commands/2.md"),
        Some("over the person's cap (25 bytes)")
    );
    let caps = Caps { entries: 3, ..Caps::default() };
    let by_count = plan(home, &none(), caps).unwrap();
    assert_eq!(by_count.manifest.len(), 3);
    assert_eq!(reason(&by_count, ".claude/commands/4.md"), Some("over the entry cap (3)"));
}

#[test]
fn project_memory_is_keyed_by_project_id_never_by_slug() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let work = tmp.path().join("work");
    // A checkout found through a transcript's cwd.
    let cmux = work.join("cmux");
    checkout(&cmux, "git@github.com:Manaflow-AI/cmux.git");
    let cmux_slug = claude_slug(cmux.to_str().unwrap());
    transcript(&home, &cmux_slug, cmux.to_str().unwrap());
    put(&home, &format!(".claude/projects/{cmux_slug}/memory/MEMORY.md"), "- one\n");
    put(&home, &format!(".claude/projects/{cmux_slug}/memory/notes/a.md"), "a\n");
    // A checkout named on the command line, with no transcript.
    let other = work.join("other.repo");
    checkout(&other, "https://github.com/o/other");
    let other_slug = claude_slug(other.to_str().unwrap());
    put(&home, &format!(".claude/projects/{other_slug}/memory/x.md"), "x\n");
    // A slug no folder here maps to.
    put(&home, ".claude/projects/-gone-folder/memory/y.md", "y\n");
    // A transcript cwd whose slug is not this slug does not count for it.
    transcript(&home, "-gone-folder", cmux.to_str().unwrap());

    let sources = Sources { folders: vec![other.clone()], ledger: None };
    let plan = plan(&home, &sources, Caps::default()).unwrap();
    let by_path: BTreeMap<&str, &Carried> =
        plan.manifest.iter().map(|entry| (entry.path.as_str(), entry)).collect();
    let note = by_path[format!(".claude/projects/{cmux_slug}/memory/notes/a.md").as_str()];
    assert_eq!(note.project.as_deref(), Some("git:github.com/manaflow-ai/cmux"));
    assert_eq!(note.name.as_deref(), Some("notes/a.md"));
    let x = by_path[format!(".claude/projects/{other_slug}/memory/x.md").as_str()];
    assert_eq!(x.project.as_deref(), Some("git:github.com/o/other"));
    assert_eq!(plan.manifest.len(), 3);
    assert_eq!(
        reason(&plan, ".claude/projects/-gone-folder/memory/y.md"),
        Some("project unmapped")
    );
    // Transcripts themselves are never carried or listed.
    assert!(plan.refused.iter().all(|refused| !refused.path.ends_with(".jsonl")));
    let states: BTreeMap<&str, &str> =
        plan.projects.iter().map(|mapped| (mapped.slug.as_str(), mapped.state)).collect();
    assert_eq!(states[cmux_slug.as_str()], "mapped");
    assert_eq!(states["-gone-folder"], "unmapped");
}

#[test]
fn two_projects_on_one_slug_are_a_conflict_and_neither_is_carried() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    // `a-b` and `a/b` share Claude's slug.
    let dashed = tmp.path().join("w").join("a-b");
    let nested = tmp.path().join("w").join("a").join("b");
    checkout(&dashed, "https://github.com/o/dashed");
    checkout(&nested, "https://github.com/o/nested");
    let slug = claude_slug(dashed.to_str().unwrap());
    assert_eq!(slug, claude_slug(nested.to_str().unwrap()));
    transcript(&home, &slug, dashed.to_str().unwrap());
    put(&home, &format!(".claude/projects/{slug}/memory/m.md"), "m\n");
    let sources = Sources { folders: vec![nested.clone()], ledger: None };
    let plan = plan(&home, &sources, Caps::default()).unwrap();
    assert!(plan.manifest.is_empty());
    assert_eq!(
        reason(&plan, &format!(".claude/projects/{slug}/memory/m.md")),
        Some("project conflict")
    );
    let mapped = &plan.projects[0];
    assert_eq!((mapped.state, mapped.project.as_deref()), ("conflict", None));
    assert_eq!(mapped.folders.len(), 2);
    // Two folders with one remote (a clone and its worktree) are one project.
    checkout(&nested, "https://github.com/o/dashed");
    let plan = super::plan(&home, &sources, Caps::default()).unwrap();
    assert_eq!(plan.manifest[0].project.as_deref(), Some("git:github.com/o/dashed"));
}

#[test]
fn a_folder_with_no_remote_takes_its_start_chat_folder_id() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let folder = tmp.path().join("scratch");
    std::fs::create_dir_all(&folder).unwrap();
    let slug = claude_slug(folder.to_str().unwrap());
    put(&home, &format!(".claude/projects/{slug}/memory/m.md"), "m\n");
    let mut sources = Sources { folders: vec![folder.clone()], ledger: None };
    let plan = plan(&home, &sources, Caps::default()).unwrap();
    assert_eq!(
        reason(&plan, &format!(".claude/projects/{slug}/memory/m.md")),
        Some("project unmapped")
    );
    let ledger_dir = tmp.path().join("state");
    std::fs::create_dir_all(&ledger_dir).unwrap();
    sources.ledger = Some(ledger_dir.join("ledger.json"));
    let first = super::plan(&home, &sources, Caps::default()).unwrap();
    let id = first.manifest[0].project.clone().unwrap();
    assert!(id.starts_with("folder:"), "{id}");
    // Stable on this device.
    let again = super::plan(&home, &sources, Caps::default()).unwrap();
    assert_eq!(again.manifest[0].project.as_deref(), Some(id.as_str()));
}

#[test]
fn the_cli_prints_the_manifest_as_json() {
    let tmp = tempfile::tempdir().unwrap();
    put(tmp.path(), ".claude/CLAUDE.md", "hi\n");
    put(tmp.path(), ".claude/.credentials.json", "{}\n");
    let home = tmp.path().to_str().unwrap().to_string();
    let args: Vec<String> = ["--home", &home, "--json"].iter().map(|arg| arg.to_string()).collect();
    let value = run(&args).unwrap();
    assert_eq!(value["ok"], json!(true));
    assert_eq!(value["verb"], json!("plan"));
    assert_eq!(value["manifest"][0]["path"], json!(".claude/CLAUDE.md"));
    assert_eq!(value["manifest"][0]["sha256"], json!(sha256_hex(b"hi\n")));
    assert_eq!(
        value["refused"][0],
        json!({"path": ".claude/.credentials.json", "reason": "never carried"})
    );
    assert_eq!(value["caps"]["file_bytes"], json!(FILE_MAX));
    let bad: Vec<String> = ["--nope".to_string()].to_vec();
    assert!(run(&bad).unwrap_err().to_string().starts_with("usage"));
}
