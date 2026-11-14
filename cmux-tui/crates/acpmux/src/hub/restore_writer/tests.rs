/// Every append of a chat's journal record is `append_record_locked`'s (the restore's own
/// records aside, `journal_restore.rs`): no other code calls the store's `append`, so nothing
/// takes a seq while a restore owns the chat but through the writer that parks it. An import
/// writes a new chat's log before it is listed; the machine journal is no chat's.
#[test]
fn a_chat_journal_is_appended_in_one_place() {
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/src");
    let allowed = ["hub/mod.rs", "hub/journal_restore.rs", "hub/transfer.rs", "write_journal.rs"];
    // A bench home's fixture and the store's stress tests write their own homes, no hub's.
    let fixtures = ["god_fixture.rs", "stress/"];
    let mut found = Vec::new();
    let mut dirs = vec![std::path::PathBuf::from(root)];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                dirs.push(path);
                continue;
            }
            let rel = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
            // A test module in its own file (`mod tests;` beside its source) is a test module.
            if !rel.ends_with(".rs")
                || rel.ends_with("_tests.rs")
                || rel.ends_with("/tests.rs")
                || rel.starts_with("store")
                || allowed.contains(&rel.as_str())
                || fixtures.iter().any(|f| rel.starts_with(f))
            {
                continue;
            }
            let text = std::fs::read_to_string(&path).unwrap();
            // A file's own test module may write a log directly.
            let text = text.split("#[cfg(test)]\nmod tests").next().unwrap_or_default();
            for (n, line) in text.lines().enumerate() {
                if line.contains("store.append(") || line.contains(".append_line(") {
                    found.push(format!("{rel}:{}: {}", n + 1, line.trim()));
                }
            }
        }
    }
    assert!(found.is_empty(), "a chat's journal appended past its writer:\n{}", found.join("\n"));
}
