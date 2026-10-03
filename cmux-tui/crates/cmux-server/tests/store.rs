//! Store apply, refusal, unpack safety, flip atomicity, rollback and GC.

mod common;

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_server::error::ExitKind;
use cmux_server::store::unpack::{Limits, unpack};
use cmux_server::store::{ApplyRequest, Store};
use cmux_server_core::Platform;
use common::*;

const FAR: &str = "2027-01-01T00:00:00Z";

struct Fixture {
    _tmp: tempfile::TempDir,
    store: Store,
    signer: Signer,
    fetcher: MapFetcher,
}

fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    Fixture {
        store: Store::new(&layout),
        _tmp: tmp,
        signer: Signer::new(7),
        fetcher: MapFetcher::default(),
    }
}

impl Fixture {
    fn apply_bytes(
        &self,
        manifest: &[u8],
        signature: &[u8],
    ) -> cmux_server::Result<cmux_server::store::ApplyReport> {
        let keys = [self.signer.key("current")];
        let req = ApplyRequest {
            manifest,
            signature,
            keys: &keys,
            channel: "stable",
            running_cmux: "1.0.0",
            roles: &["server"],
            now_ms: NOW_MS,
        };
        self.store.apply(&req, &self.fetcher)
    }

    fn apply(&self, manifest: &[u8]) -> cmux_server::Result<cmux_server::store::ApplyReport> {
        self.apply_bytes(manifest, &self.signer.sign(manifest))
    }

    fn release(&self, sequence: u64, tag: &str) -> Vec<u8> {
        let cmux =
            Pkg { name: "cmux", version: "1.0.0", archive: bin_package("cmux", tag.as_bytes()) };
        self.fetcher.serve(&cmux);
        manifest(sequence, FAR, "1.0.0", &[&cmux])
    }
}

fn current_body(store: &Store) -> String {
    fs::read_to_string(store.current.join("bin/cmux")).unwrap()
}

#[test]
fn apply_builds_profile_flips_current_and_is_idempotent() {
    let f = fixture();
    let m1 = f.release(1, "v1");
    let r = f.apply(&m1).unwrap();
    assert_eq!((r.from, r.to, r.changed, r.reapply), (None, 1, true, false));
    assert_eq!(r.fetched, ["cmux"]);
    assert_eq!(current_body(&f.store), "v1");
    assert_eq!(f.store.current_generation(), Some(1));
    assert_eq!(fs::read_link(&f.store.current).unwrap(), Path::new("profiles/1"));
    // The package tree is read-only after unpack.
    let pkg = f.store.current.join("pkgs/cmux/bin/cmux");
    assert!(fs::metadata(&pkg).unwrap().permissions().readonly());
    // Re-running the same manifest is a no-op: store hit, no flip.
    let hits_before = f.fetcher.hit_count();
    let again = f.apply(&m1).unwrap();
    assert_eq!((again.changed, again.reapply), (false, true));
    assert_eq!(again.store_hits, ["cmux"]);
    assert_eq!(f.fetcher.hit_count(), hits_before, "no download on a store hit");
    assert_eq!(f.store.last_applied().unwrap().unwrap().sequence, 1);
}

#[test]
fn tampered_package_is_refused_and_current_does_not_move() {
    let f = fixture();
    f.apply(&f.release(1, "v1")).unwrap();
    let good = Pkg { name: "cmux", version: "2.0.0", archive: bin_package("cmux", b"v2") };
    let m2 = manifest(2, FAR, "1.0.0", &[&good]);
    // Same size, one byte changed.
    let mut bad = good.archive.clone();
    let last = bad.len() - 9;
    bad[last] ^= 0xff;
    f.fetcher.put(&good.url(), bad);
    let err = f.apply(&m2).unwrap_err();
    assert_eq!(err.kind, ExitKind::Verification, "{err}");
    assert!(err.message.contains("SHA-256 mismatch"), "{err}");
    assert_eq!(f.store.current_generation(), Some(1));
    assert_eq!(current_body(&f.store), "v1");
    // A longer body is refused by size before it is hashed in full.
    let mut long = good.archive.clone();
    long.push(0);
    f.fetcher.put(&good.url(), long);
    assert_eq!(f.apply(&m2).unwrap_err().kind, ExitKind::Verification);
    assert_eq!(f.store.last_applied().unwrap().unwrap().sequence, 1);
}

#[test]
fn core_refusals_map_to_verification_failed() {
    let f = fixture();
    f.apply(&f.release(2, "v2")).unwrap();
    // Lower sequence (downgrade or replay).
    let m1 = f.release(1, "v1");
    let err = f.apply(&m1).unwrap_err();
    assert_eq!(err.kind, ExitKind::Verification);
    assert!(err.message.contains("lower than the last applied 2"), "{err}");
    // Same sequence, other bytes.
    let other = f.release(2, "v2-other");
    assert_eq!(f.apply(&other).unwrap_err().kind, ExitKind::Verification);
    // Untrusted key.
    let m3 = f.release(3, "v3");
    let err = f.apply_bytes(&m3, &Signer::new(9).sign(&m3)).unwrap_err();
    assert_eq!(err.kind, ExitKind::Verification);
    // Expired.
    let cmux = Pkg { name: "cmux", version: "3", archive: bin_package("cmux", b"x") };
    let expired = manifest(4, "2026-01-01T00:00:00Z", "1.0.0", &[&cmux]);
    assert_eq!(f.apply(&expired).unwrap_err().kind, ExitKind::Verification);
    assert_eq!(f.store.current_generation(), Some(2));
}

#[test]
fn needs_newer_cmux_stages_only_cmux_and_refuses() {
    let f = fixture();
    let cmux = Pkg { name: "cmux", version: "9.0.0", archive: bin_package("cmux", b"new") };
    let tool = Pkg { name: "tool", version: "1", archive: bin_package("tool", b"t") };
    f.fetcher.serve(&cmux);
    f.fetcher.serve(&tool);
    let m = manifest(5, FAR, "9.0.0", &[&cmux, &tool]);
    let err = f.apply(&m).unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected);
    assert!(err.message.contains("needs cmux 9.0.0"), "{err}");
    assert!(f.store.store.join(sha_hex(&cmux.archive)).join(".cmux-package").is_file());
    assert!(!f.store.store.join(sha_hex(&tool.archive)).exists());
    assert_eq!(f.store.current_generation(), None);
}

#[test]
fn rollback_and_gc_keep_three_profiles_and_current() {
    let f = fixture();
    for g in 1..=5 {
        f.apply(&f.release(g, &format!("v{g}"))).unwrap();
    }
    assert_eq!(f.store.generations(), [3, 4, 5]);
    let packages = fs::read_dir(&f.store.store).unwrap().count();
    assert_eq!(packages, 3, "packages of removed profiles are collected");
    let flip = f.store.rollback(None).unwrap();
    assert_eq!((flip.from, flip.to), (Some(5), 4));
    assert_eq!(current_body(&f.store), "v4");
    let flip = f.store.rollback(Some(3)).unwrap();
    assert_eq!(flip.to, 3);
    assert_eq!(f.store.rollback(Some(1)).unwrap_err().kind, ExitKind::NotFound);
    assert_eq!(f.store.rollback(None).unwrap_err().kind, ExitKind::NotFound);
    // A new apply flips forward and collects the oldest profile.
    f.apply(&f.release(6, "v6")).unwrap();
    assert_eq!(f.store.generations(), [4, 5, 6]);
    f.apply(&f.release(7, "v7")).unwrap();
    assert_eq!(f.store.generations(), [5, 6, 7]);
    // GC never removes the profile `current` points at.
    f.store.rollback(Some(5)).unwrap();
    f.store.gc(1).unwrap();
    assert_eq!(f.store.generations(), [5, 7]);
    assert_eq!(current_body(&f.store), "v5");
    // Rolled back below the last applied: the same manifest flips forward.
    f.store.rollback(Some(5)).unwrap();
    let m7 = f.release(7, "v7");
    let r = f.apply(&m7).unwrap();
    assert_eq!((r.from, r.to, r.changed, r.reapply), (Some(5), 7, true, true));
}

/// Review 8 / decision A: 20,000 flips with readers doing readlink, stat
/// and open through `current` the whole time, and zero reader errors (on
/// macOS 26.5, an unpinned rename(2) over a symlink gave about 2,600).
#[test]
fn flip_is_atomic_for_readers() {
    const FLIPS: u64 = 20_000;
    let f = fixture();
    f.apply(&f.release(1, "v1")).unwrap();
    f.apply(&f.release(2, "v2")).unwrap();
    let current = f.store.current.clone();
    let stop = Arc::new(AtomicBool::new(false));
    let readers: Vec<_> = (0..3)
        .map(|kind| {
            let stop = stop.clone();
            let current = current.clone();
            std::thread::spawn(move || {
                let (mut reads, mut errors) = (0u64, Vec::new());
                while !stop.load(Ordering::Relaxed) {
                    let result = match kind {
                        0 => fs::read_link(&current).and_then(|t| {
                            (t == Path::new("profiles/1") || t == Path::new("profiles/2"))
                                .then_some(())
                                .ok_or_else(|| std::io::Error::other(format!("target {t:?}")))
                        }),
                        1 => fs::metadata(&current).map(|_| ()),
                        _ => fs::File::open(current.join("packages.json")).map(|_| ()),
                    };
                    reads += 1;
                    if let Err(e) = result
                        && errors.len() < 5
                    {
                        errors.push(e.to_string());
                    }
                }
                (reads, errors)
            })
        })
        .collect();
    for i in 0..FLIPS {
        f.store.switch_to(1 + i % 2).unwrap();
    }
    stop.store(true, Ordering::Relaxed);
    for (kind, reader) in readers.into_iter().enumerate() {
        let (reads, errors) = reader.join().unwrap();
        assert!(reads > 0, "reader {kind} never ran");
        assert!(errors.is_empty(), "reader {kind}: {reads} reads, errors {errors:?}");
    }
    let names: Vec<String> = fs::read_dir(&f.store.root)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(!names.iter().any(|n| n.contains(".swap.")), "no temporary links remain");
    let pins = names.iter().filter(|n| n.starts_with(".current.pin.")).count();
    assert!(pins <= cmux_server::fsx::PIN_MAX_COUNT, "{pins} pins kept");
}

#[test]
fn flips_pin_the_old_link_and_old_pins_are_removed() {
    use std::time::Duration;
    let f = fixture();
    f.apply(&f.release(1, "v1")).unwrap();
    f.apply(&f.release(2, "v2")).unwrap();
    for i in 0..4 {
        f.store.switch_to(1 + i % 2).unwrap();
    }
    let pins = || -> Vec<String> {
        fs::read_dir(&f.store.root)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with(".current.pin."))
            .collect()
    };
    // Fresh pins stay (younger than PIN_MAX_AGE); each is the old symlink.
    let fresh = pins();
    assert!(fresh.len() >= 4, "{fresh:?}");
    for name in &fresh {
        assert!(!name.contains(".swap."), "{name}");
        let target = fs::read_link(f.store.root.join(name)).unwrap();
        assert!(target == Path::new("profiles/1") || target == Path::new("profiles/2"));
    }
    // Pins at least max_age old are removed (zero: all of them).
    cmux_server::fsx::prune_pins(&f.store.current, Duration::ZERO, 0).unwrap();
    assert!(pins().is_empty(), "{:?}", pins());
    assert!(fs::read_link(&f.store.current).is_ok(), "current itself stays");
    // Uninstall leaves no pin behind, so the root goes away.
    f.store.switch_to(1).unwrap();
    f.store.remove_all().unwrap();
    assert!(!f.store.root.exists());
}

#[test]
fn concurrent_apply_is_refused_while_the_lock_is_held() {
    let f = fixture();
    let _held = cmux_server::store::state::StoreLock::acquire(&f.store.root).unwrap();
    let err = f.apply(&f.release(1, "v1")).unwrap_err();
    assert_eq!(err.kind, ExitKind::Unreachable, "{err}");
}

/// Unpacks `bytes` as they are (no gzip added).
fn try_unpack_raw(bytes: &[u8]) -> cmux_server::Result<tempfile::TempDir> {
    let tmp = tempfile::tempdir().unwrap();
    let archive = tmp.path().join("a.tar.gz");
    fs::write(&archive, bytes).unwrap();
    unpack(&archive, &tmp.path().join("out"), Limits::for_archive(bytes.len() as u64)).map(|()| tmp)
}

fn try_unpack(tar: &[u8]) -> cmux_server::Result<tempfile::TempDir> {
    try_unpack_raw(&gzip(tar))
}

#[test]
fn unpack_accepts_only_tar_gz() {
    // Decision SV-R3: tar.gz only; CI wraps single binaries.
    let tar = raw_tar(&[raw_entry(b"bin/cmux", tar::EntryType::Regular, b"", b"hi")]);
    let mut zip = b"PK\x03\x04".to_vec();
    zip.extend_from_slice(&[0; 64]);
    let cases: Vec<(&str, Vec<u8>, &str)> = vec![
        ("plain tar", tar.clone(), "uncompressed tar"),
        ("bare ELF binary", b"\x7fELF\x02\x01\x01rest".to_vec(), "ELF"),
        ("bare Mach-O binary", vec![0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1], "Mach-O"),
        ("zip", zip, "zip"),
        ("xz", vec![0xfd, b'7', b'z', b'X', b'Z', 0, 0, 4], "xz"),
        ("shell script", b"#!/bin/sh\necho hi\n".to_vec(), "unknown"),
        ("gzip of a bare binary", gzip(&[0x7f; 2000]), "gzip but not tar"),
        ("empty gzip", gzip(b""), "no tar entries"),
    ];
    for (name, bytes, says) in cases {
        let tmp = tempfile::tempdir().unwrap();
        let archive = tmp.path().join("pkg");
        fs::write(&archive, &bytes).unwrap();
        let out = tmp.path().join("out");
        let err = unpack(&archive, &out, Limits::for_archive(bytes.len() as u64))
            .err()
            .unwrap_or_else(|| panic!("{name} was accepted"));
        assert_eq!(err.kind, ExitKind::Rejected, "{name}: {err}");
        assert!(err.message.contains(says) && err.message.contains("tar.gz"), "{name}: {err}");
        if !name.contains("gzip") {
            assert!(!out.exists(), "{name}: nothing is written for a refused format");
        }
    }
    let tmp = try_unpack(&tar).unwrap();
    assert_eq!(fs::read_to_string(tmp.path().join("out/bin/cmux")).unwrap(), "hi");
    // A broken gzip stream is corrupt (verification), not "not tar".
    let big = raw_tar(&[raw_entry(b"bin/big", tar::EntryType::Regular, b"", &noise(64 << 10))]);
    let gz = gzip(&big);
    let err = try_unpack_raw(&gz[..gz.len() / 2]).expect_err("a truncated gzip was accepted");
    assert_eq!(err.kind, ExitKind::Verification, "{err}");
    assert!(err.message.contains("corrupt"), "{err}");
}

/// Bytes that do not compress.
fn noise(len: usize) -> Vec<u8> {
    let mut x: u32 = 0x9e37_79b9;
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x as u8
        })
        .collect()
}

#[test]
fn a_package_that_is_not_tar_gz_is_refused_and_current_does_not_move() {
    let f = fixture();
    f.apply(&f.release(1, "v1")).unwrap();
    let bare = Pkg { name: "cmux", version: "2.0.0", archive: b"\x7fELF\x02\x01bare".to_vec() };
    f.fetcher.serve(&bare);
    let err = f.apply(&manifest(2, FAR, "1.0.0", &[&bare])).unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    assert!(err.message.contains("tar.gz only"), "{err}");
    assert_eq!(f.store.current_generation(), Some(1));
    assert!(!f.store.store.join(sha_hex(&bare.archive)).exists());
}

#[test]
fn unpack_refuses_traversal_absolute_and_escaping_links() {
    use tar::EntryType::{Link, Regular, Symlink};
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("dotdot", raw_tar(&[raw_entry(b"../evil", Regular, b"", b"x")])),
        ("nested dotdot", raw_tar(&[raw_entry(b"bin/../../evil", Regular, b"", b"x")])),
        ("absolute", raw_tar(&[raw_entry(b"/tmp/evil", Regular, b"", b"x")])),
        ("escaping symlink", raw_tar(&[raw_entry(b"bin/x", Symlink, b"../../etc/passwd", b"")])),
        ("absolute symlink", raw_tar(&[raw_entry(b"bin/x", Symlink, b"/etc/passwd", b"")])),
        ("hard link", raw_tar(&[raw_entry(b"bin/x", Link, b"bin/y", b"")])),
        (
            "write through a symlink",
            raw_tar(&[
                raw_entry(b"lib", Symlink, b"bin", b""),
                raw_entry(b"lib/x", Regular, b"", b"x"),
            ]),
        ),
        (
            "duplicate file",
            raw_tar(&[raw_entry(b"a", Regular, b"", b"1"), raw_entry(b"a", Regular, b"", b"2")]),
        ),
        (
            // Each link passes the lexical check; x resolves to the
            // package's parent through a/b/up.
            "symlink chain, .. after a symlink",
            raw_tar(&[
                raw_entry(b"a/b/up", Symlink, b"../..", b""),
                raw_entry(b"x", Symlink, b"a/b/up/..", b""),
            ]),
        ),
        (
            // The link that x walks through is created after x, so only
            // the resolution after unpack can see the escape.
            "symlink chain created out of order",
            raw_tar(&[
                raw_entry(b"a/b/keep", Regular, b"", b"k"),
                raw_entry(b"x", Symlink, b"a/b/c/..", b""),
                raw_entry(b"a/b/c", Symlink, b"../..", b""),
            ]),
        ),
        ("dangling symlink", raw_tar(&[raw_entry(b"bin/x", Symlink, b"missing", b"")])),
    ];
    for (name, tar) in cases {
        let err = try_unpack(&tar).err().unwrap_or_else(|| panic!("{name} was accepted"));
        assert_eq!(err.kind, ExitKind::Verification, "{name}: {err}");
    }
    // An inside symlink and `./` prefixes are fine.
    let ok = raw_tar(&[
        raw_entry(b"./bin/real", Regular, b"", b"hi"),
        raw_entry(b"bin/alias", Symlink, b"real", b""),
        raw_entry(b"lib/link", Symlink, b"../bin/real", b""),
    ]);
    let tmp = try_unpack(&ok).unwrap();
    assert_eq!(fs::read_to_string(tmp.path().join("out/lib/link")).unwrap(), "hi");
}

#[test]
fn unpack_enforces_the_size_limit() {
    let tar = raw_tar(&[raw_entry(b"big", tar::EntryType::Regular, b"", &vec![0u8; 4096])]);
    let tmp = tempfile::tempdir().unwrap();
    let archive = tmp.path().join("a.tar.gz");
    fs::write(&archive, gzip(&tar)).unwrap();
    let limits = Limits { max_bytes: 1024, max_entries: 10 };
    let err = unpack(&archive, &tmp.path().join("out"), limits).unwrap_err();
    assert_eq!(err.kind, ExitKind::Verification);
}

#[test]
fn https_fetcher_refuses_http_unless_built_for_tests() {
    use cmux_server::store::fetch::{Fetch, HttpsFetcher, check_url};
    let strict = HttpsFetcher::new().unwrap();
    let err = strict.open("http://127.0.0.1:9/x").err().unwrap();
    assert_eq!(err.kind, ExitKind::Rejected);
    assert!(check_url("https://cmux.com@evil.example/x", false).is_err());
    assert!(check_url("ftp://cmux.com/x", true).is_err());
    assert!(check_url("http://127.0.0.1:8765/x", true).is_ok());
    assert!(check_url("https://files.cmux.com/a.tar.gz", false).is_ok());
}

#[test]
fn remove_all_keeps_state() {
    let f = fixture();
    f.apply(&f.release(1, "v1")).unwrap();
    f.store.remove_all().unwrap();
    assert!(!f.store.store.exists() && !f.store.profiles.exists());
    assert!(!cmux_server::fsx::exists_no_follow(&f.store.current));
    assert!(f.store.record.is_file(), "the updater record stays with the state");
    // A reinstall still refuses an older manifest.
    assert_eq!(f.apply(&f.release(0, "v0")).unwrap_err().kind, ExitKind::Verification);
}

#[cfg(unix)]
#[test]
fn apply_never_changes_the_store_root_mode() {
    use std::os::unix::fs::PermissionsExt;
    let f = fixture();
    fs::create_dir_all(&f.store.root).unwrap();
    fs::set_permissions(&f.store.root, fs::Permissions::from_mode(0o755)).unwrap();
    f.apply(&f.release(1, "v1")).unwrap();
    f.store.rollback(Some(1)).unwrap();
    let mode = fs::metadata(&f.store.root).unwrap().permissions().mode() & 0o7777;
    assert_eq!(mode, 0o755, "the root keeps the mode core's access policy gave it");
}

#[test]
fn http_status_maps_to_exit_codes() {
    use cmux_server::store::fetch::status_error;
    assert_eq!(status_error("u", 404).kind, ExitKind::NotFound);
    assert_eq!(status_error("u", 410).kind, ExitKind::NotFound);
    assert_eq!(status_error("u", 403).kind, ExitKind::Rejected);
    assert_eq!(status_error("u", 503).kind, ExitKind::Unreachable);
}
