use super::*;
use serde_json::json;

fn dir() -> tempfile::TempDir {
    let d = tempfile::tempdir().unwrap();
    std::fs::create_dir(d.path().join(".git")).unwrap();
    std::fs::create_dir_all(d.path().join("src/sub")).unwrap();
    d
}

fn lines(n: usize) -> String {
    (1..=n).map(|i| format!("line {i}\n")).collect()
}

#[test]
fn extracts_paths_lines_and_cues() {
    let refs = extract(
        "Read /abs/a.md first. Then `src/b.rs:12-40` and src/c.rs:7:3, see x.py#L3-L9; \
         not https://e.com/a.rs, not -flag, not $HOME/x, README.md, and (src/d.rs).",
    );
    let got: Vec<(&str, Option<(usize, usize)>, bool)> =
        refs.iter().map(|r| (r.path.as_str(), r.lines, r.cued)).collect();
    assert_eq!(
        got,
        vec![
            ("/abs/a.md", None, true),
            ("src/b.rs", Some((12, 40)), false),
            ("src/c.rs", Some((7, 7)), false),
            ("x.py", Some((3, 9)), true),
            ("README.md", None, false),
            ("src/d.rs", None, false),
        ]
    );
    assert!(extract("no paths here at all, version 1.2 and e.g. and 3.14").is_empty());
    assert_eq!(extract("see main.c").len(), 1);
}

#[test]
fn switch_defaults_on_and_turns_off() {
    assert!(enabled_by(None, None));
    assert!(enabled_by(Some(&json!({})), Some("1")));
    assert!(!enabled_by(None, Some("0")));
    assert!(!enabled_by(
        Some(&json!({"agents": {"harnessMagic": {"prefetch": {"enabled": false}}}})),
        None
    ));
    assert!(!enabled_by(Some(&json!({"agents.harnessMagic.prefetch.enabled": false})), None));
}

#[test]
fn blob_hash_is_gits() {
    // `printf 'hello\n' | git hash-object --stdin`
    assert_eq!(blob_hash(b"hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a");
}

#[test]
fn secrets_are_skipped() {
    for p in [
        "/r/.env",
        "/r/.env.local",
        "/r/aws_credentials.json",
        "/h/.ssh/config",
        "/r/server.pem",
        "/r/id_ed25519.pub",
        "/h/.config/gh/hosts.yml",
    ] {
        assert!(secret_looking(Path::new(p)), "{p}");
    }
    for p in ["/r/src/main.rs", "/r/README.md", "/r/docs/env.md"] {
        assert!(!secret_looking(Path::new(p)), "{p}");
    }
}

#[test]
fn plans_whole_files_and_windows_with_labels() {
    let d = dir();
    std::fs::write(d.path().join("src/a.rs"), "fn a() {}\n").unwrap();
    std::fs::write(d.path().join("src/big.rs"), lines(1000)).unwrap();
    std::fs::write(d.path().join(".env"), "KEY=1\n").unwrap();
    std::fs::write(d.path().join("bin.dat"), [0u8, 1, 2, 3]).unwrap();
    let sub = d.path().join("src/sub");
    // Named from a subfolder: `src/a.rs` resolves against the git root.
    let p = plan("Read src/a.rs, src/big.rs:500, .env and bin.dat", &sub, None, true).unwrap();
    assert_eq!(p.files.len(), 2);
    assert_eq!(p.files[0].ranges, vec![(1, 1)]);
    assert_eq!(p.files[0].blob, blob_hash(b"fn a() {}\n"));
    assert_eq!(p.files[1].ranges, vec![(420, 580)]);
    let text = p.block["text"].as_str().unwrap();
    assert!(text.starts_with("<cmux-prefetch-context>"));
    assert!(crate::prompt_context::is_context(&p.block));
    assert!(crate::prompt_context::is_context_text(text));
    assert!(text.contains("lines=\"420-580\" totalLines=\"1000\""));
    assert!(text.contains("   500\tline 500\n"));
    assert!(!text.contains("line 419\n") && !text.contains("KEY=1"));
    assert_eq!(p.tokens, text.len().div_ceil(4));
}

#[test]
fn budgets_hold_and_later_prompts_take_only_cued() {
    let d = dir();
    std::fs::write(d.path().join("big.rs"), lines(10_000)).unwrap();
    std::fs::write(d.path().join("a.md"), lines(10)).unwrap();
    std::fs::write(d.path().join("b.md"), lines(10)).unwrap();
    // A whole file over its budget is not cut in half.
    assert!(plan("look at big.rs", d.path(), None, true).is_none());
    // Later prompt: the uncued a.md is left out, the cued b.md is in.
    let p = plan("a.md changed; read b.md", d.path(), None, false).unwrap();
    assert_eq!(p.files.len(), 1);
    assert!(p.files[0].path.ends_with("b.md"));
    let first = plan("a.md changed; read b.md", d.path(), None, true).unwrap();
    assert_eq!(first.files.len(), 2);
    // A total budget that fits one file takes one.
    let one = plan_within("a.md b.md", d.path(), None, true, 300, 300).unwrap();
    assert_eq!(one.files.len(), 1);
    // Outside the folder, its git root and home: nothing.
    let other = dir();
    std::fs::write(other.path().join("x.md"), "x\n").unwrap();
    let outside = format!("read {}", other.path().join("x.md").display());
    assert!(plan(&outside, d.path(), None, true).is_none());
}

#[test]
fn counts_rereads_of_prefetched_files() {
    let d = dir();
    std::fs::write(d.path().join("a.md"), lines(3)).unwrap();
    std::fs::write(d.path().join("b.md"), lines(3)).unwrap();
    std::fs::write(d.path().join("c.md"), lines(3)).unwrap();
    let p = plan("read a.md, b.md and c.md", d.path(), None, true).unwrap();
    let canon = |n: &str| std::fs::canonicalize(d.path().join(n)).unwrap().display().to_string();
    let mut t = PrefetchTurn::new("t1", &p);
    // Claude's Read, first without its input, then with it; counted once.
    t.observe(
        &json!({"sessionUpdate": "tool_call", "toolCallId": "r1", "kind": "read", "title": "Read"}),
    );
    let read = json!({"sessionUpdate": "tool_call_update", "toolCallId": "r1", "kind": "read", "rawInput": {"file_path": canon("a.md")}, "locations": [{"path": canon("a.md")}]});
    t.observe(&read);
    t.observe(&read);
    // Codex's shell read by a relative name.
    t.observe(&json!({"sessionUpdate": "tool_call", "toolCallId": "s1", "kind": "execute", "rawInput": {"command": ["bash", "-lc", "sed -n 1,3p b.md"]}}));
    // An edit is not a read; another file is not prefetched.
    t.observe(&json!({"sessionUpdate": "tool_call", "toolCallId": "e1", "kind": "edit", "rawInput": {"file_path": canon("c.md")}}));
    t.observe(&json!({"sessionUpdate": "tool_call", "toolCallId": "r2", "kind": "read", "rawInput": {"file_path": "/elsewhere/z.md"}}));
    let c = t.counters();
    assert_eq!(c["harnessMagic.prefetch.files"], 3);
    assert_eq!(c["harnessMagic.prefetch.rereadAnyway"], 2);
    assert_eq!(c["harnessMagic.prefetch.neverRead"], 1);
    assert_eq!(c["harnessMagic.prefetch.tokens"], p.tokens);
    // 3 * 0.239 - 2 < 0: nothing saved.
    assert_eq!(c["harnessMagic.prefetch.estRequestsSaved"], 0.0);
    let untouched = PrefetchTurn::new("t2", &p).counters();
    assert_eq!(untouched["harnessMagic.prefetch.estRequestsSaved"], 0.72);
}
