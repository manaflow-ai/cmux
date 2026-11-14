use super::*;

fn bridge() -> (tempfile::TempDir, Bridge) {
    let dir = tempfile::tempdir().unwrap();
    let bridge = Bridge::new(dir.path().join("bridge"));
    (dir, bridge)
}

#[test]
fn an_app_is_named_by_its_address_harness_or_name() {
    assert_eq!(app("codex").unwrap().address, "codex-desktop");
    assert_eq!(app("Claude Desktop").unwrap().address, "claude-desktop");
    assert_eq!(app(" claude-desktop ").unwrap().name, "Claude Desktop");
    assert!(app("gemini").is_none());
}

#[test]
fn claude_desktop_messages_codex_desktop_and_codex_reads_it_once() {
    let (_dir, bridge) = bridge();
    let codex = app("codex").unwrap();
    bridge.send("Claude Desktop", codex, "first").unwrap();
    bridge.send("Claude Desktop", codex, "second").unwrap();

    let (peeked, _) = bridge.inbox(codex, false).unwrap();
    assert_eq!(peeked.len(), 2, "a peek leaves them unread");

    let (read, more) = bridge.inbox(codex, true).unwrap();
    assert_eq!(read.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), ["first", "second"]);
    assert_eq!(read[0].from, "Claude Desktop");
    assert_eq!(more, 0);
    assert!(bridge.inbox(codex, true).unwrap().0.is_empty(), "read once");
    assert!(bridge.inbox(app("claude").unwrap(), true).unwrap().0.is_empty());
}

#[test]
fn an_empty_message_or_sender_is_refused() {
    let (_dir, bridge) = bridge();
    let codex = app("codex").unwrap();
    assert!(bridge.send("x", codex, "  ").is_err());
    assert!(bridge.send(" ", codex, "hi").is_err());
}

/// A message the person or an agent sends goes whole, whatever its size: no 64 KiB limit.
#[test]
fn send_path_a_bridge_message_of_any_size_is_delivered_whole() {
    let (_dir, bridge) = bridge();
    let codex = app("codex").unwrap();
    let text = "a long paste ".repeat(5 * 1024 * 1024 / 13);
    assert!(text.len() > 4 << 20);
    bridge.send("Claude Desktop", codex, &text).unwrap();
    let (read, more) = bridge.inbox(codex, true).unwrap();
    assert_eq!(more, 0);
    assert_eq!(read.len(), 1);
    assert_eq!(read[0].text, text.trim());
}

#[test]
fn a_read_returns_at_most_max_read_and_counts_the_rest() {
    let (_dir, bridge) = bridge();
    let claude = app("claude").unwrap();
    for i in 0..MAX_READ + 3 {
        bridge.send("Codex Desktop", claude, &format!("m{i}")).unwrap();
    }
    let (read, more) = bridge.inbox(claude, true).unwrap();
    assert_eq!((read.len(), more), (MAX_READ, 3));
    assert_eq!(read[0].text, "m0");
    assert_eq!(bridge.inbox(claude, true).unwrap().0.len(), 3);
}

#[test]
fn a_file_that_is_not_a_message_does_not_block_the_rest() {
    let (dir, bridge) = bridge();
    let codex = app("codex").unwrap();
    let new = dir.path().join("bridge/codex-desktop/new");
    std::fs::create_dir_all(&new).unwrap();
    std::fs::write(new.join("0000000000000-junk.json"), b"not json").unwrap();
    bridge.send("Claude Desktop", codex, "hello").unwrap();
    let (read, _) = bridge.inbox(codex, true).unwrap();
    assert_eq!(read.len(), 1);
    assert!(json_files(&new).unwrap().is_empty());
}

#[test]
fn old_read_messages_are_pruned() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("0000000000001-a.json"), b"{}").unwrap();
    let fresh = format!("{:013}-b.json", now_ms());
    std::fs::write(dir.path().join(&fresh), b"{}").unwrap();
    prune(dir.path(), READ_KEEP);
    assert_eq!(json_files(dir.path()).unwrap(), [fresh]);
}
