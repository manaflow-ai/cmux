use super::*;

fn payload(edit: impl FnOnce(&mut serde_json::Map<String, Value>)) -> String {
    let sha = "b".repeat(64);
    let mut body = json!({
        "schema": 1, "channel": "every-merge", "key": "a".repeat(64),
        "archive": format!("web-bundles-{sha}.tar.gz"), "sha256": sha, "size": 42,
        "outputs": "c".repeat(64), "abi": 2, "commit": "1".repeat(40),
        "committed_at": 1_760_000_000, "published_at": 1_760_000_060,
    });
    edit(body.as_object_mut().unwrap());
    body.to_string()
}

/// The payload of WebUpdatePointerTests.scriptEnvelope (web-ota-pointer.py's bytes).
const SCRIPT_PAYLOAD: &str = r#"{"abi":2,"archive":"web-bundles-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tar.gz","channel":"every-merge","commit":"1111111111111111111111111111111111111111","committed_at":1760000000,"key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","outputs":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","published_at":1792547795,"schema":1,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":42}"#;

#[test]
fn the_script_payload_reads() {
    let pointer = read_pointer(SCRIPT_PAYLOAD, "every-merge").unwrap();
    assert_eq!((pointer.abi, pointer.committed_at, pointer.size), (2, 1_760_000_000, 42));
    assert_eq!(pointer.cas, None);
    let back = serde_json::to_value(&pointer).unwrap();
    assert_eq!(back["published_at"], json!(1_792_547_795));
    assert!(back.get("cas").is_none());
}

#[test]
fn another_channel_and_malformed_fields_are_refused() {
    assert_eq!(
        read_pointer(SCRIPT_PAYLOAD, "nightly"),
        Err(Refusal::WrongChannel("every-merge".into()))
    );
    let bad = payload(|b| {
        b.insert("archive".into(), json!("../../etc/passwd"));
    });
    assert_eq!(read_pointer(&bad, "every-merge"), Err(Refusal::Malformed("archive name".into())));
    let huge = payload(|b| {
        b.insert("size".into(), json!(MAXIMUM_SIZE + 1));
    });
    assert_eq!(
        read_pointer(&huge, "every-merge"),
        Err(Refusal::Malformed(format!("size {}", MAXIMUM_SIZE + 1)))
    );
    let schema = payload(|b| {
        b.insert("schema".into(), json!(2));
    });
    assert_eq!(
        read_pointer(&schema, "every-merge"),
        Err(Refusal::Malformed("not a pointer payload".into()))
    );
    let digest = payload(|b| {
        b.insert("key".into(), json!("A".repeat(64)));
    });
    assert_eq!(read_pointer(&digest, "every-merge"), Err(Refusal::Malformed("bad digest".into())));
    let abi = payload(|b| {
        b.insert("abi".into(), json!(0));
    });
    assert_eq!(read_pointer(&abi, "every-merge"), Err(Refusal::Malformed("commit or abi".into())));
    assert!(read_pointer("[]", "every-merge").is_err());
}

#[test]
fn a_cas_field_is_read_and_a_malformed_one_dropped() {
    let cas =
        json!({"prefix": "cmux-next-web/cas/", "manifest": "e".repeat(64), "pack": "f".repeat(64)});
    let good = payload(|b| {
        b.insert("cas".into(), cas.clone());
    });
    assert_eq!(
        read_pointer(&good, "every-merge").unwrap().cas,
        Some(Cas {
            prefix: "cmux-next-web/cas/".into(),
            manifest: "e".repeat(64),
            pack: "f".repeat(64)
        })
    );
    for bad in [
        json!({"prefix": "../x/", "manifest": "e".repeat(64), "pack": "f".repeat(64)}),
        json!({"prefix": "cmux-next-web/cas/", "manifest": "e", "pack": "f".repeat(64)}),
        json!({"prefix": "cmux-next-web/cas", "manifest": "e".repeat(64), "pack": "f".repeat(64)}),
        json!({"prefix": "/", "manifest": "e".repeat(64), "pack": "f".repeat(64)}),
        json!("not an object"),
    ] {
        let text = payload(|b| {
            b.insert("cas".into(), bad);
        });
        assert_eq!(read_pointer(&text, "every-merge").unwrap().cas, None);
    }
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-web-updates-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// The digest web-bundle-key.py --outputs computes, written out by hand.
#[test]
fn the_tree_digest_follows_the_script() {
    let root = scratch("digest");
    let pages = root.join(OUTPUTS[1]);
    fs::create_dir_all(pages.join("sub")).unwrap();
    fs::write(pages.join("b.js"), "b").unwrap();
    fs::write(pages.join("a.js"), "a").unwrap();
    fs::write(pages.join(".DS_Store"), "x").unwrap();
    fs::write(pages.join("sub/c.js"), "c").unwrap();
    fs::create_dir_all(root.join(OUTPUTS[0])).unwrap();
    let file = |rel: &str, body: &str| format!("{rel}\0{}\n", hex(&Sha256::digest(body)));
    let p = OUTPUTS[1];
    let expected = [
        format!("empty {}\n", OUTPUTS[0]),
        file(&format!("{p}/a.js"), "a"),
        file(&format!("{p}/b.js"), "b"),
        file(&format!("{p}/sub/c.js"), "c"),
        format!("missing {}\n", OUTPUTS[2]),
        format!("missing {}\n", OUTPUTS[3]),
        format!("missing {}\n", OUTPUTS[4]),
    ]
    .concat();
    assert_eq!(tree_digest(&root), Ok(hex(&Sha256::digest(expected))));
    std::os::unix::fs::symlink("a.js", pages.join("z.js")).unwrap();
    assert_eq!(tree_digest(&root), Err(Refusal::Integrity("link z.js".into())));
    let reply = call("web_updates.tree_digest", &json!({"root": root})).unwrap();
    assert_eq!(reply, json!({"refusal": {"kind": "integrity", "detail": "link z.js"}}));
    fs::remove_dir_all(&root).unwrap();
}

/// WebUpdateStoreTests' fixture tree and the digest web-bundle-key.py
/// printed for it (measured there, never derived by hand).
#[test]
fn the_swift_fixture_tree_digests_as_the_script_measured() {
    let root = scratch("fixture");
    let pane = OUTPUTS[0];
    for (rel, text) in [
        (format!("{pane}/index.html"), "pane\n"),
        (format!("{pane}/assets/a.js"), "a\n"),
        (format!("{pane}/Z.js"), "z\n"),
        (format!("{pane}/.DS_Store"), "x"),
        (format!("{}/web-abi.json", OUTPUTS[1]), "{\"abi\": 2}\n"),
        (format!("{}/settings/index.html", OUTPUTS[1]), "s\n"),
        (OUTPUTS[4].to_owned(), "i\n"),
    ] {
        let file = root.join(rel);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }
    fs::create_dir_all(root.join(OUTPUTS[2])).unwrap();
    assert_eq!(
        tree_digest(&root).as_deref(),
        Ok("82ba929a93ebcc51609a84991ecf129ff7036ba20694bee83abe737ed152e704")
    );
    fs::remove_dir_all(&root).unwrap();
}

/// OUTPUTS is web-bundle-key.py's list, in its order.
#[test]
fn outputs_are_the_scripts() {
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../scripts/cmux-next/web-bundle-key.py");
    let text = fs::read_to_string(script).unwrap();
    let list = text.split("OUTPUTS = [").nth(1).unwrap().split(']').next().unwrap();
    let names: Vec<&str> = list
        .lines()
        .map(|l| l.trim().trim_end_matches(',').trim_matches('"'))
        .filter(|l| !l.is_empty())
        .collect();
    assert_eq!(names, OUTPUTS);
}

#[test]
fn the_archive_digest_is_its_size_and_sha256() {
    let dir = scratch("archive");
    let file = dir.join("a.tar.gz");
    fs::write(&file, "hello").unwrap();
    assert_eq!(archive_digest(&file), Ok((5, hex(&Sha256::digest("hello")))));
    assert_eq!(
        archive_digest(&dir.join("none")),
        Err(Refusal::Integrity("unreadable archive".into()))
    );
    fs::remove_dir_all(&dir).unwrap();
}
