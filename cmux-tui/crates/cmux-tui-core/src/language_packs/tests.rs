#![cfg(unix)]

use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime};

use serde_json::json;
use sha2::{Digest as _, Sha256};

use super::*;

/// A folder of this test's own, removed when dropped.
struct Folder(PathBuf);

impl Folder {
    fn new(label: &str) -> Self {
        let mut random = [0u8; 6];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-language-packs-{label}-{suffix}"));
        std::fs::create_dir_all(&path).unwrap();
        Self(std::fs::canonicalize(path).unwrap())
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn sha(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// A tar of `(path, Some(contents))` files and `(path, None)` folders, zstd-compressed. Names are
/// written into the header as they are, so a test can write one the tar writer would refuse.
fn archive(entries: &[(&str, Option<&[u8]>)]) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    for (path, contents) in entries {
        let mut header = tar::Header::new_old();
        let name = path.as_bytes();
        header.as_old_mut().name[..name.len()].copy_from_slice(name);
        match contents {
            Some(bytes) => {
                header.set_entry_type(tar::EntryType::Regular);
                header.set_size(bytes.len() as u64);
                header.set_mode(0o644);
                header.set_cksum();
                builder.append(&header, *bytes).unwrap();
            }
            None => {
                header.set_entry_type(tar::EntryType::Directory);
                header.set_size(0);
                header.set_mode(0o755);
                header.set_cksum();
                builder.append(&header, std::io::empty()).unwrap();
            }
        }
    }
    zstd::encode_all(&builder.into_inner().unwrap()[..], 3).unwrap()
}

/// A loopback server that answers every GET with `body`, counting the connections.
struct Server {
    url: String,
    requests: Arc<AtomicUsize>,
}

impl Server {
    fn start(body: Vec<u8>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let url = format!("http://127.0.0.1:{port}/language-packs/de.tar.zst");
        let requests = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&requests);
        let body = Arc::new(body);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                counter.fetch_add(1, Ordering::SeqCst);
                let body = Arc::clone(&body);
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(&body);
                });
            }
        });
        Self { url, requests }
    }
}

fn manifest_file(folder: &Path, packs: Value) -> PathBuf {
    let path = folder.join("language-packs.json");
    std::fs::write(&path, serde_json::to_vec(&json!({"version": 1, "packs": packs})).unwrap())
        .unwrap();
    path
}

fn request(language: &str, manifest: PathBuf, cache: PathBuf) -> Request {
    Request { language: language.into(), manifest, cache }
}

const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[test]
fn a_manifest_is_version_1_with_well_formed_packs() {
    let good = |url: &str, sha256: &str, size: u64| {
        serde_json::to_vec(&json!({"version": 1, "packs": {"de": {
            "url": url, "sha256": sha256, "size": size}}}))
        .unwrap()
    };
    let url = "https://files-next.cmux.com/language-packs/x/de.tar.zst";
    let manifest = parse_manifest(&good(url, SHA_A, 10)).unwrap();
    // The first manifests had no `chromium` or `strings`: a strings-only pack.
    assert_eq!(
        manifest.packs["de"],
        Pack { url: url.into(), sha256: SHA_A.into(), size: 10, chromium: None, strings: true }
    );
    assert!(parse_manifest(br#"{"version": 1, "packs": {}}"#).is_ok());

    let bad = [
        br#"{"version": 2, "packs": {}}"#.to_vec(),
        br#"{"packs": {}}"#.to_vec(),
        b"not json".to_vec(),
        good(url, &SHA_A.to_uppercase(), 10),
        good(url, &SHA_A[1..], 10),
        good(url, SHA_A, 0),
        good(url, SHA_A, PACK_SIZE_LIMIT + 1),
        good("https://example.com/de.tar.zst", SHA_A, 10),
        good("http://files-next.cmux.com/de.tar.zst", SHA_A, 10),
        good("https://files-next.cmux.com:8443/de.tar.zst", SHA_A, 10),
        good("https://user@files-next.cmux.com/de.tar.zst", SHA_A, 10),
        good("file:///etc/passwd", SHA_A, 10),
    ];
    for bytes in bad {
        assert_eq!(
            parse_manifest(&bytes).unwrap_err(),
            Code::BadManifest,
            "{}",
            String::from_utf8_lossy(&bytes)
        );
    }
}

#[test]
fn a_pack_names_a_downloadable_chromium_locale_and_carries_something() {
    let pack = |extra: Value| {
        let mut pack = json!({"url": "https://files-next.cmux.com/language-packs/x/sv.tar.zst",
            "sha256": SHA_A, "size": 10});
        pack.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        serde_json::to_vec(&json!({"version": 1, "packs": {"sv": pack}})).unwrap()
    };
    for good in [
        json!({"chromium": "sv", "strings": false}),
        json!({"chromium": "zh_CN", "strings": true}),
        json!({"chromium": "es_419", "strings": false}),
        json!({"chromium": "pt_PT", "strings": false}),
        json!({"chromium": "en_GB", "strings": false}),
        json!({"strings": true}),
    ] {
        assert!(parse_manifest(&pack(good.clone())).is_ok(), "{good}");
    }
    for bad in [
        // en-US is the app's fallback, never a download.
        json!({"chromium": "en", "strings": false}),
        // Not a pak Chromium builds for macOS (an extended locale, a gendered or pseudo one).
        json!({"chromium": "cy", "strings": false}),
        json!({"chromium": "de_FEMININE", "strings": false}),
        json!({"chromium": "en_XA", "strings": false}),
        json!({"chromium": "../de", "strings": false}),
        // A pack that carries nothing.
        json!({"strings": false}),
    ] {
        assert_eq!(parse_manifest(&pack(bad.clone())).unwrap_err(), Code::BadManifest, "{bad}");
    }
}

#[test]
fn chromium_locales_are_chromiums_macos_paks() {
    assert_eq!(CHROMIUM_LOCALES.len(), 55);
    let mut sorted = CHROMIUM_LOCALES.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(sorted, CHROMIUM_LOCALES.to_vec(), "sorted, each once");
    // The 22 the app shipped before, the regional ones Leo kept (2026-11-12) among them.
    for shipped in [
        "ar", "da", "de", "en", "en_GB", "es", "es_419", "fr", "it", "ja", "ko", "nb", "pl",
        "pt_BR", "pt_PT", "ru", "th", "tr", "uk", "vi", "zh_CN", "zh_TW",
    ] {
        assert!(CHROMIUM_LOCALES.contains(&shipped), "{shipped}");
    }
    assert!(!is_downloadable_chromium_locale("en"));
    assert_eq!(CHROMIUM_LOCALES.iter().filter(|c| is_downloadable_chromium_locale(c)).count(), 54);
}

#[test]
fn a_pack_with_a_chromium_pak_answers_its_path() {
    let folder = Folder::new("chromium-pak");
    let cache = folder.path().join("cache");
    let body = archive(&[("ChromiumLocales/sv.lproj/locale.pak", Some(b"pak"))]);
    let sha256 = sha(&body);
    let server = Server::start(body.clone());
    let manifest = manifest_file(
        folder.path(),
        json!({"sv": {"url": server.url, "sha256": sha256, "size": body.len(),
            "chromium": "sv", "strings": false}}),
    );
    let root = cache.join(&sha256);
    let pak = root.join("ChromiumLocales/sv.lproj/locale.pak");
    let outcome = ensure(&request("sv", manifest.clone(), cache.clone()));
    assert_eq!(outcome, Outcome::Ready { root: root.clone(), chromium_pak: Some(pak.clone()) });
    assert_eq!(
        outcome.to_json(),
        json!({"state": "ready", "root": root.to_string_lossy(),
            "chromium_pak": pak.to_string_lossy()})
    );
    assert_eq!(std::fs::read(&pak).unwrap(), b"pak");

    // A whole folder without its pinned pak was changed on disk: it is downloaded again.
    std::fs::remove_file(&pak).unwrap();
    let again = ensure(&request("sv", manifest, cache));
    assert_eq!(again, Outcome::Ready { root, chromium_pak: Some(pak.clone()) });
    assert_eq!(std::fs::read(&pak).unwrap(), b"pak");
    assert_eq!(server.requests.load(Ordering::SeqCst), 2);
}

#[test]
fn loopback_is_allowed_only_for_tests_and_debug_builds() {
    assert!(allowed_url("http://127.0.0.1:4000/de.tar.zst"));
    assert!(allowed_url("http://localhost:4000/de.tar.zst"));
    assert!(!allowed_url("http://10.0.0.1/de.tar.zst"));
    assert!(!allowed_url("ftp://files-next.cmux.com/de.tar.zst"));
}

#[test]
fn english_no_manifest_and_no_pack_are_bundled() {
    let folder = Folder::new("bundled");
    let cache = folder.path().join("cache");
    let missing = folder.path().join("missing.json");
    assert_eq!(ensure(&request("en", missing.clone(), cache.clone())), Outcome::Bundled);
    assert_eq!(ensure(&request("", missing.clone(), cache.clone())), Outcome::Bundled);
    assert_eq!(ensure(&request("de", missing, cache.clone())), Outcome::Bundled);
    let manifest = manifest_file(folder.path(), json!({}));
    assert_eq!(ensure(&request("ja", manifest, cache.clone())), Outcome::Bundled);
    assert!(!cache.exists(), "a bundled answer makes no cache folder");
}

#[test]
fn a_bad_manifest_is_unavailable() {
    let folder = Folder::new("bad-manifest");
    let manifest = folder.path().join("language-packs.json");
    std::fs::write(&manifest, br#"{"version": 9, "packs": {}}"#).unwrap();
    let outcome = ensure(&request("de", manifest, folder.path().join("cache")));
    assert_eq!(outcome, Outcome::Unavailable(Code::BadManifest));
    assert_eq!(outcome.to_json()["code"], "language_packs.bad_manifest");
    assert_eq!(outcome.to_json()["state"], "unavailable");
    assert!(outcome.to_json()["message"].as_str().is_some_and(|text| !text.is_empty()));
}

#[test]
fn a_complete_pack_is_ready_without_network() {
    let folder = Folder::new("cache-hit");
    let cache = folder.path().join("cache");
    let root = cache.join(SHA_A);
    std::fs::create_dir_all(root.join("de.lproj")).unwrap();
    std::fs::write(root.join(COMPLETE), SHA_A).unwrap();
    // Nothing listens on port 9 of loopback: a download would be offline.
    let manifest = manifest_file(
        folder.path(),
        json!({"de": {"url": "http://127.0.0.1:9/de.tar.zst", "sha256": SHA_A, "size": 10}}),
    );
    let outcome = ensure(&request("de", manifest, cache));
    assert_eq!(outcome, Outcome::Ready { root: root.clone(), chromium_pak: None });
    assert_eq!(outcome.to_json(), json!({"state": "ready", "root": root.to_string_lossy()}));
}

#[test]
fn a_pack_without_its_marker_is_downloaded_again() {
    let folder = Folder::new("no-marker");
    let cache = folder.path().join("cache");
    let body = archive(&[("de.lproj/Localizable.strings", Some(b"\"a\" = \"b\";"))]);
    let sha256 = sha(&body);
    std::fs::create_dir_all(cache.join(&sha256)).unwrap();
    let server = Server::start(body.clone());
    let manifest = manifest_file(
        folder.path(),
        json!({"de": {"url": server.url, "sha256": sha256, "size": body.len()}}),
    );
    let outcome = ensure(&request("de", manifest, cache.clone()));
    assert_eq!(outcome, Outcome::Ready { root: cache.join(&sha256), chromium_pak: None });
    assert!(cache.join(&sha256).join("de.lproj/Localizable.strings").is_file());
    assert_eq!(server.requests.load(Ordering::SeqCst), 1);
}

#[test]
fn a_pack_downloads_once_unpacks_and_prunes_the_old_ones() {
    let folder = Folder::new("download");
    let cache = folder.path().join("cache");
    let body = archive(&[
        ("./de.lproj", None),
        ("./de.lproj/Localizable.strings", Some(b"\"Hello\" = \"Hallo\";")),
        ("de.lproj/nested/Other.strings", Some(b"x")),
    ]);
    let sha256 = sha(&body);
    let server = Server::start(body.clone());
    // An old pack, a pack still listed (another language), a fresh and a stale partial.
    std::fs::create_dir_all(cache.join(SHA_A)).unwrap();
    std::fs::create_dir_all(cache.join(SHA_B)).unwrap();
    std::fs::create_dir_all(cache.join(".partial-fresh")).unwrap();
    let stale = cache.join(".partial-stale");
    std::fs::create_dir_all(&stale).unwrap();
    std::fs::File::open(&stale)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(2 * 60 * 60))
        .unwrap();
    std::fs::write(cache.join("unrelated.txt"), b"kept").unwrap();
    let manifest = manifest_file(
        folder.path(),
        json!({
            "de": {"url": server.url, "sha256": sha256, "size": body.len()},
            "ja": {"url": "https://files-next.cmux.com/ja.tar.zst", "sha256": SHA_B, "size": 1},
        }),
    );

    let threads: Vec<_> = (0..4)
        .map(|_| {
            let request = request("de", manifest.clone(), cache.clone());
            std::thread::spawn(move || ensure(&request))
        })
        .collect();
    let root = cache.join(&sha256);
    for thread in threads {
        assert_eq!(
            thread.join().unwrap(),
            Outcome::Ready { root: root.clone(), chromium_pak: None }
        );
    }
    assert_eq!(server.requests.load(Ordering::SeqCst), 1, "one download for every request");
    assert_eq!(
        std::fs::read(root.join("de.lproj/Localizable.strings")).unwrap(),
        b"\"Hello\" = \"Hallo\";"
    );
    assert!(root.join("de.lproj/nested/Other.strings").is_file());
    assert_eq!(std::fs::read_to_string(root.join(COMPLETE)).unwrap(), sha256);

    assert!(!cache.join(SHA_A).exists(), "a pack the manifest no longer names goes");
    assert!(cache.join(SHA_B).exists(), "a pack of another listed language stays");
    assert!(cache.join(".partial-fresh").exists(), "a partial of a running install stays");
    assert!(!stale.exists(), "a partial older than an hour goes");
    assert!(cache.join("unrelated.txt").exists());
    let leftovers: Vec<_> = std::fs::read_dir(&cache)
        .unwrap()
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().contains(&sha256[..16]))
        .map(|entry| entry.file_name())
        .collect();
    assert_eq!(leftovers, vec![std::ffi::OsString::from(&sha256)], "no download file is left");
}

#[test]
fn a_hash_or_size_mismatch_is_verify_and_leaves_nothing() {
    let folder = Folder::new("mismatch");
    let cache = folder.path().join("cache");
    let body = archive(&[("de.lproj/Localizable.strings", Some(b"x"))]);
    let server = Server::start(body.clone());
    for (sha256, size) in
        [(SHA_A.to_owned(), body.len()), (sha(&body), body.len() - 1), (sha(&body), body.len() + 1)]
    {
        let manifest = manifest_file(
            folder.path(),
            json!({"de": {"url": server.url, "sha256": sha256, "size": size}}),
        );
        assert_eq!(
            ensure(&request("de", manifest, cache.clone())),
            Outcome::Unavailable(Code::Verify)
        );
        let left: Vec<_> = std::fs::read_dir(&cache).unwrap().flatten().collect();
        assert!(left.is_empty(), "{left:?}");
    }
}

#[test]
fn an_unreachable_server_is_offline() {
    let folder = Folder::new("offline");
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let manifest = manifest_file(
        folder.path(),
        json!({"de": {"url": format!("http://127.0.0.1:{port}/de.tar.zst"), "sha256": SHA_A,
            "size": 10}}),
    );
    let outcome = ensure(&request("de", manifest, folder.path().join("cache")));
    assert_eq!(outcome, Outcome::Unavailable(Code::Offline));
}

#[test]
fn unpack_refuses_names_that_escape_links_and_the_marker() {
    let folder = Folder::new("escape");
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("parent", archive(&[("../evil", Some(b"x"))])),
        ("nested parent", archive(&[("de.lproj/../../evil", Some(b"x"))])),
        ("absolute", archive(&[("/tmp/cmux-language-packs-evil", Some(b"x"))])),
        ("marker", archive(&[(COMPLETE, Some(b"x"))])),
        ("not zstd", b"plain bytes".to_vec()),
        ("symlink", {
            let mut builder = tar::Builder::new(Vec::new());
            let mut header = tar::Header::new_gnu();
            header.set_entry_type(tar::EntryType::Symlink);
            header.set_path("de.lproj").unwrap();
            header.set_link_name("/etc").unwrap();
            header.set_size(0);
            header.set_cksum();
            builder.append(&header, std::io::empty()).unwrap();
            zstd::encode_all(&builder.into_inner().unwrap()[..], 3).unwrap()
        }),
    ];
    for (label, bytes) in cases {
        let archive_path = folder.path().join(format!("{label}.tar.zst"));
        std::fs::write(&archive_path, &bytes).unwrap();
        let into = folder.path().join(format!("into-{label}"));
        std::fs::create_dir(&into).unwrap();
        assert_eq!(unpack(&archive_path, &into), Err(Code::Verify), "{label}");
    }
    assert!(!folder.path().join("evil").exists());
    assert!(!Path::new("/tmp/cmux-language-packs-evil").exists());
}

#[test]
fn prune_keeps_listed_packs_and_young_partials() {
    let folder = Folder::new("prune");
    let cache = folder.path();
    std::fs::create_dir(cache.join(SHA_A)).unwrap();
    std::fs::create_dir(cache.join(SHA_B)).unwrap();
    std::fs::create_dir(cache.join(".partial-young")).unwrap();
    std::fs::write(cache.join(".partial-young.tar.zst"), b"x").unwrap();
    let keep: HashSet<&str> = [SHA_A].into_iter().collect();
    prune(cache, &keep, SystemTime::now());
    assert!(cache.join(SHA_A).exists());
    assert!(!cache.join(SHA_B).exists());
    assert!(cache.join(".partial-young").exists());
    assert!(cache.join(".partial-young.tar.zst").exists());
    // Two hours on, both partials are stale.
    prune(cache, &keep, SystemTime::now() + Duration::from_secs(2 * 60 * 60));
    assert!(!cache.join(".partial-young").exists());
    assert!(!cache.join(".partial-young.tar.zst").exists());
    assert!(cache.join(SHA_A).exists());
}

#[test]
fn a_request_needs_absolute_paths() {
    let fields = |manifest: &str, cache: &str| {
        json!({"language": " de ", "manifest": manifest, "cache": cache})
            .as_object()
            .cloned()
            .unwrap()
    };
    let parsed = parse_request(&fields("/a/language-packs.json", "/c")).unwrap();
    assert_eq!(parsed, request("de", "/a/language-packs.json".into(), "/c".into()));
    for (manifest, cache) in [("relative.json", "/c"), ("/a.json", "c"), ("/a/../b.json", "/c")] {
        let error = parse_request(&fields(manifest, cache)).unwrap_err();
        assert_eq!(error.code, "validation.invalid");
    }
}

#[test]
fn an_offline_download_is_tried_again_before_it_is_reported() {
    let tries = std::cell::Cell::new(0);
    let outcome = retry_offline(
        || {
            tries.set(tries.get() + 1);
            if tries.get() < 3 { Err(Code::Offline) } else { Ok(()) }
        },
        Duration::from_secs(10),
    );
    assert_eq!(outcome, Ok(()));
    assert_eq!(tries.get(), 3);
}

#[test]
fn a_bad_download_is_not_tried_again() {
    let tries = std::cell::Cell::new(0);
    let outcome = retry_offline(
        || {
            tries.set(tries.get() + 1);
            Err(Code::Verify)
        },
        Duration::from_secs(10),
    );
    assert_eq!(outcome, Err(Code::Verify));
    assert_eq!(tries.get(), 1);
}
