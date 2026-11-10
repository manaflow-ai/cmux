//! The hunk summary's pure parts: its key, prompt, sentence and the bounded cache on disk.

use super::*;

const PATCH: &str = "@@ -10,3 +10,6 @@ fn upload()\n-    send(file)?;\n+    for _ in 0..3 {\n+        if send(file).is_ok() { return Ok(()); }\n+    }\n+    Err(Gave::Up)\n";

fn scratch(name: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("acpmux-hunk-summary-{}-{name}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn key_is_the_hunks_content() {
    let a = key("src/upload.rs", PATCH);
    assert!(is_key(&a), "{a}");
    assert_eq!(a, key("src/upload.rs", PATCH), "the same hunk has the same key");
    assert_ne!(a, key("src/other.rs", PATCH), "another file's hunk is another key");
    assert_ne!(a, key("src/upload.rs", &PATCH.replace('3', "4")), "a changed hunk is a new key");
    // The parts are separated: a path ending where a patch starts is not the same input.
    assert_ne!(key("ab", "c"), key("a", "bc"));
}

#[test]
fn is_key_names_a_file_only() {
    assert!(!is_key("../../etc/passwd"));
    assert!(!is_key(&"A".repeat(64)));
    assert!(!is_key(&"a".repeat(63)));
    assert!(is_key(&"0".repeat(64)));
}

#[test]
fn prompt_holds_the_path_and_patch() {
    let p = prompt("src/upload.rs", PATCH, crate::complete::MAX_PROMPT_BYTES);
    assert!(p.contains("one plain English sentence"), "{p}");
    assert!(p.contains("File: src/upload.rs"), "{p}");
    assert!(p.contains("+    for _ in 0..3 {"), "{p}");
    assert!(!p.contains("was cut"), "{p}");
    assert!(p.len() <= crate::complete::MAX_PROMPT_BYTES);
}

#[test]
fn a_long_hunk_is_cut_on_a_line_within_the_limit() {
    let long: String = (0..2000).map(|i| format!("+line number {i} of the new file\n")).collect();
    let p = prompt("src/big.rs", &long, crate::complete::MAX_PROMPT_BYTES);
    assert!(p.len() <= crate::complete::MAX_PROMPT_BYTES, "{} bytes", p.len());
    assert!(p.contains("(the rest of this hunk was cut)"), "{p}");
    let body = p.split("```diff\n").nth(1).unwrap();
    for line in body.lines().take_while(|l| !l.starts_with("(the rest")) {
        assert!(
            line.starts_with("+line number ") && line.ends_with("of the new file"),
            "cut line {line:?}"
        );
    }
    // A path is cut too, on a character boundary.
    let p = prompt(&"é".repeat(400), PATCH, crate::complete::MAX_PROMPT_BYTES);
    assert!(p.len() <= crate::complete::MAX_PROMPT_BYTES);
}

#[test]
fn sentence_is_one_clean_line() {
    let cases = [
        (
            "Retries the upload three times before giving up.",
            "Retries the upload three times before giving up.",
        ),
        ("retries the upload three times\n\nMore text", "Retries the upload three times."),
        ("\n  \"Adds a `timeout` to the fetch\"  ", "Adds a timeout to the fetch."),
        ("- Removes the unused import", "Removes the unused import."),
        ("Does it work?", "Does it work?"),
    ];
    for (answer, want) in cases {
        assert_eq!(sentence(answer).as_deref(), Some(want), "{answer:?}");
    }
    assert_eq!(sentence("  \n\"\"\n"), None);
    let long = "Word ".repeat(200);
    assert!(sentence(&long).unwrap().len() <= 221);
}

#[test]
fn cache_keeps_a_sentence_by_key() {
    let cache = Cache::new(scratch("get").join("summaries"));
    let k = key("a.rs", PATCH);
    assert_eq!(cache.get(&k), None);
    cache.put(&k, "Retries the upload.").unwrap();
    assert_eq!(cache.get(&k).as_deref(), Some("Retries the upload."));
    // Not a key: never read or written as a path.
    assert_eq!(cache.get("../x"), None);
    assert!(cache.put("../x", "no").is_err());
}

#[test]
fn prune_removes_the_oldest_past_the_cap() {
    let cache = Cache::new(scratch("prune"));
    std::fs::create_dir_all(cache.root()).unwrap();
    let keys: Vec<String> = (0..10).map(|i| key("p", &i.to_string())).collect();
    for (i, k) in keys.iter().enumerate() {
        let path = cache.root().join(k);
        std::fs::write(&path, format!("s{i}")).unwrap();
        let at =
            std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_000 + i as u64);
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(at).unwrap();
    }
    // A file that is not a summary is never touched.
    std::fs::write(cache.root().join("notes.txt"), "keep").unwrap();
    assert_eq!(cache.prune(10, 5), 0, "at the cap nothing goes");
    assert_eq!(cache.prune(8, 6), 4);
    for (i, k) in keys.iter().enumerate() {
        assert_eq!(cache.get(k).is_some(), i >= 4, "summary {i}");
    }
    assert!(cache.root().join("notes.txt").exists());
}
