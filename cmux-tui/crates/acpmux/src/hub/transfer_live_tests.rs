use super::*;

#[test]
fn a_compressed_page_is_taken_and_a_bomb_is_refused() {
    let page = vec![b'a'; 1 << 20];
    let packed = zstd::bulk::compress(&page, 3).unwrap();
    assert!(packed.len() < page.len() / 100);
    let params = json!({"data": BASE64.encode(&packed), "encoding": "zstd"});
    assert_eq!(page_bytes(&params).unwrap(), page);
    let plain = json!({"data": BASE64.encode(b"abc")});
    assert_eq!(page_bytes(&plain).unwrap(), b"abc");
    let big = vec![0u8; (MAX_PAGE + 1) as usize];
    let bomb = json!({"data": BASE64.encode(zstd::bulk::compress(&big, 3).unwrap()),
                      "encoding": "zstd"});
    assert!(page_bytes(&bomb).is_err());
    let other = json!({"data": "", "encoding": "br"});
    assert!(page_bytes(&other).unwrap_err().message.contains("transfer.encoding"));
}

/// A stage's native files (a Claude chat's transcript) go to the receive that takes it, with
/// what each holds, so the freeze pages only what they grew by; the receive may write a
/// seeded file again from an earlier offset.
#[test]
fn a_stages_native_files_seed_the_receive() {
    let root = tempfile::tempdir().unwrap();
    let (stage, receive) = (root.path().join("in-stage"), root.path().join("in-receive"));
    let file = stage.join("bundle/native/claude/.claude/projects/p/s.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, b"{\"a\":1}\n").unwrap();
    let native = keep_staged_native(&stage);
    let path = "native/claude/.claude/projects/p/s.jsonl";
    assert_eq!(
        native,
        vec![json!({"path": path, "bytes": 8,
        "sha256": crate::sha256::sha256_hex(b"{\"a\":1}\n")})]
    );
    assert!(!stage.join("bundle/native").exists());
    std::fs::create_dir_all(&receive).unwrap();
    let staged = json!({"native": native});
    let have = seed_native(&stage, &receive, Some(&staged));
    assert_eq!(have, native);
    assert!(receive.join("bundle").join(path).is_file());
    assert!(seeded(&receive, path));
    assert!(!seeded(&receive, "events/000001.ndjson"));
}

#[test]
fn a_prefix_digest_is_of_the_first_bytes_only() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("f");
    std::fs::write(&file, b"abcdef").unwrap();
    assert_eq!(
        prefix_digest(&file, 3).unwrap().as_deref(),
        Some(crate::sha256::sha256_hex(b"abc").as_str())
    );
    assert_eq!(prefix_digest(&file, 7).unwrap(), None);
}
