use super::*;

#[test]
fn a_move_folder_is_checked_before_anything_is_made() {
    let folder = |v: Value| named_folder(v.as_object().unwrap());
    assert!(folder(json!({"home": "Projects/x"})).is_ok());
    for home in ["", "/abs", "../up", "a/../b", "a b", "x\ny"] {
        assert!(folder(json!({"home": home})).is_err(), "{home:?}");
    }
    let ok = json!({"repo": "o/n", "url": "https://github.com/o/n.git", "branch": "lane/x", "subdir": ""});
    assert!(folder(ok.clone()).is_ok());
    for (key, bad) in [
        ("repo", "o/n/x"),
        ("repo", "../n"),
        ("url", "file:///etc"),
        ("url", "https://x y"),
        ("branch", "-x"),
        ("branch", "a b"),
        ("subdir", "../x"),
    ] {
        let mut v = ok.clone();
        v[key] = json!(bad);
        assert!(folder(v).is_err(), "{key} {bad:?}");
    }
}

#[test]
fn only_a_plain_daemon_id_is_dialed() {
    assert!(plain_daemon("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    assert!(plain_daemon("inst_0123abcd"));
    for bad in ["", "short", "a b c d e f", "x\ny0000000", &"a".repeat(129)] {
        assert!(!plain_daemon(bad), "{bad:?}");
    }
}

/// A folder's manifest served page by page as `manifest_page` serves it.
struct Folder(std::path::PathBuf, u64);

impl PageSource for Folder {
    fn call<'a>(
        &'a mut self,
        method: &'a str,
        mut params: Value,
    ) -> BoxFuture<'a, Result<Value, RpcError>> {
        assert_eq!(method, "manifest");
        params["limit"] = json!(self.1);
        Box::pin(async move { manifest_page(&self.0, &params) })
    }
}

#[tokio::test]
async fn a_pulled_manifest_is_read_in_pages_and_checked_against_its_size_and_hash() {
    let dir = tempfile::tempdir().unwrap();
    let manifest = json!({"transferId": "t-1", "files": vec!["x".repeat(100); 50]});
    let reference = write_pulled_manifest(dir.path(), "t-1", &manifest).unwrap();
    assert_eq!(reference["bytes"], manifest.to_string().len());
    // Pages smaller than the whole: read across many.
    let mut pages = Folder(dir.path().to_owned(), 999);
    assert_eq!(pull_manifest(&mut pages, &reference).await.unwrap(), manifest);
    let mut wrong = reference.clone();
    wrong["sha256"] = json!("0".repeat(64));
    assert!(pull_manifest(&mut pages, &wrong).await.unwrap_err().message.contains("sha256"));
    let mut short = reference.clone();
    short["bytes"] = json!(manifest.to_string().len() - 1);
    assert!(pull_manifest(&mut pages, &short).await.is_err(), "a size that does not match");
    let mut long = reference;
    long["bytes"] = json!(MAX_PULLED_MANIFEST + 1);
    assert!(pull_manifest(&mut pages, &long).await.is_err(), "past the bound");
}

#[test]
fn only_the_old_version_refusal_reads_as_a_target_too_old() {
    let e = too_old(OLD_VERSION_REFUSAL, "machine-b", 200 * 1024 + 1).unwrap();
    assert!(e.message.contains("over 64 KiB (201 KiB)"), "{}", e.message);
    assert!(e.message.contains("`acpmux machine update machine-b`"), "{}", e.message);
    let data = e.data.unwrap();
    assert_eq!(
        (data["refused"].clone(), data["reason"].clone()),
        (json!(true), json!("transfer.target_too_old"))
    );
    assert!(too_old("transfer.cwd: outside the roots", "h", 1).is_none());
}
