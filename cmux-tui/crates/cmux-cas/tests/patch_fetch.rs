//! Per-file patches (RFD 0166 W1): a changed bundle file rebuilt from the file the client holds,
//! paired across a build-hash rename, checked by hash, and the chunks taking over on any miss.

use cmux_cas::Store;
use cmux_cas::fetch::{DirSource, Report, fetch};
use cmux_cas::patch;
use cmux_cas::publish::{publish, publish_with_bases};
use std::path::Path;

fn noise(n: usize, seed: u64) -> Vec<u8> {
    let mut s = seed | 1;
    (0..n)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            b"abcdefghij(){};=,.\n "[(s % 20) as usize]
        })
        .collect()
}

fn write(root: &Path, path: &str, bytes: &[u8]) {
    let p = root.join(path);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, bytes).unwrap();
}

/// A minified bundle rebuilt: the same text with a small edit every 20 KiB, so every FastCDC
/// chunk changes and only a patch is small.
fn rebuilt(old: &[u8]) -> Vec<u8> {
    let mut new = old.to_vec();
    for at in (5000..new.len()).step_by(20 << 10) {
        new[at] = b'Z';
    }
    new
}

fn fetch_into(
    r2: &Path,
    store: &Path,
    p: &cmux_cas::publish::Published,
    have: &[&Path],
    out: &Path,
) -> Report {
    let have: Vec<_> = have.iter().map(|h| h.to_path_buf()).collect();
    fetch(&mut DirSource(r2.to_path_buf()), &Store::new(store), &p.manifest, &p.pack, &have, out)
        .unwrap()
}

#[test]
fn a_rebuilt_file_comes_by_patch_across_a_rename() {
    let t = tempfile::tempdir().unwrap();
    let (v1, v2, r2) = (t.path().join("v1"), t.path().join("v2"), t.path().join("r2"));
    let app = noise(2 << 20, 3);
    let app2 = rebuilt(&app);
    write(&v1, "agent-pane/chunks/App-26IGK243.js", &app);
    write(&v1, "agent-pane/index.html", b"<html>1</html>");
    write(&v2, "agent-pane/chunks/App-RU6BSLRW.js", &app2);
    write(&v2, "agent-pane/index.html", b"<html>2</html>");
    // Two shared chunks share the stem `chunk-*.js`: each pairs with the nearer in size.
    let (small, big) = (noise(200 << 10, 5), noise(600 << 10, 7));
    write(&v1, "agent-pane/chunks/chunk-AAAA1111.js", &small);
    write(&v1, "agent-pane/chunks/chunk-BBBB2222.js", &big);
    write(&v1, "agent-pane/chunks/chunk-CCCC3333.js", &noise(64 << 10, 11));
    write(&v2, "agent-pane/chunks/chunk-DDDD4444.js", &rebuilt(&big));

    let plain = publish(&v2, &t.path().join("plain")).unwrap();
    let chunks = fetch_into(
        &t.path().join("plain"),
        &t.path().join("s0"),
        &plain,
        &[v1.as_path()],
        &t.path().join("o0"),
    );
    assert_eq!(chunks.patches, 0);

    let published = publish_with_bases(&v2, &[v1.as_path()], &r2).unwrap();
    assert_eq!(published.manifest, plain.manifest);
    assert_eq!(published.patches, Some(2));
    let warm = t.path().join("warm");
    let report = fetch_into(&r2, &t.path().join("s1"), &published, &[v1.as_path()], &warm);
    assert_eq!(report.patches, 2, "{report:?}");
    assert_eq!(report.patch_misses, 0);
    assert_eq!(std::fs::read(warm.join("agent-pane/chunks/App-RU6BSLRW.js")).unwrap(), app2);
    assert_eq!(std::fs::read(warm.join("agent-pane/index.html")).unwrap(), b"<html>2</html>");
    let by_patch = report.patch_bytes + report.range_bytes;
    let by_chunks = chunks.range_bytes;
    assert!(by_patch * 10 < by_chunks, "patch {report:?} chunks {chunks:?}");

    // Cold: nothing held, so no patch applies and the pack serves it all.
    let cold = fetch_into(&r2, &t.path().join("s2"), &published, &[], &t.path().join("cold"));
    assert_eq!(cold.patches, 0);
    assert_eq!(cold.range_bytes, published.pack_bytes);
}

#[test]
fn a_bad_patch_falls_back_to_the_chunks() {
    let t = tempfile::tempdir().unwrap();
    let (v1, v2, r2) = (t.path().join("v1"), t.path().join("v2"), t.path().join("r2"));
    let app = noise(1 << 20, 9);
    let app2 = rebuilt(&app);
    write(&v1, "main.mjs", &app);
    write(&v2, "main.mjs", &app2);
    let published = publish_with_bases(&v2, &[v1.as_path()], &r2).unwrap();
    let list: patch::List = patch::List::from_bytes(
        &std::fs::read(r2.join(patch::list_path(&published.manifest))).unwrap(),
    )
    .unwrap();
    let p = list.patches[0];
    let path = r2.join(patch::patch_path(&p.to, &p.from));
    let mut bytes = std::fs::read(&path).unwrap();
    let mid = bytes.len() / 2;
    bytes[mid] ^= 0x55;
    std::fs::write(&path, bytes).unwrap();

    let out = t.path().join("out");
    let report = fetch_into(&r2, &t.path().join("s"), &published, &[v1.as_path()], &out);
    assert_eq!((report.patches, report.patch_misses), (0, 1), "{report:?}");
    assert!(report.range_bytes > 0);
    assert_eq!(std::fs::read(out.join("main.mjs")).unwrap(), app2);

    // No list at all: chunks, no miss counted.
    std::fs::remove_file(r2.join(patch::list_path(&published.manifest))).unwrap();
    let report =
        fetch_into(&r2, &t.path().join("s3"), &published, &[v1.as_path()], &t.path().join("o3"));
    assert_eq!((report.patches, report.patch_misses), (0, 0));
}

/// The W1 measurement on two real web update trees: `CAS_OLD=DIR CAS_NEW=DIR cargo test -p
/// cmux-cas --release --test patch_fetch real_pair -- --ignored --nocapture`.
#[test]
#[ignore = "needs two unpacked web bundle trees"]
fn real_pair() {
    let (Ok(old), Ok(new)) = (std::env::var("CAS_OLD"), std::env::var("CAS_NEW")) else {
        panic!("set CAS_OLD and CAS_NEW");
    };
    let (old, new) = (Path::new(&old), Path::new(&new));
    let t = tempfile::tempdir().unwrap();
    let r2 = t.path().join("r2");
    let started = std::time::Instant::now();
    let published = publish_with_bases(new, &[old], &r2).unwrap();
    let publish_ms = started.elapsed().as_millis();
    // Chunks alone first (cold page cache for the store either way), then with the list.
    let list = std::fs::read(r2.join(patch::list_path(&published.manifest))).unwrap();
    std::fs::remove_file(r2.join(patch::list_path(&published.manifest))).unwrap();
    let started = std::time::Instant::now();
    let chunks = fetch_into(&r2, &t.path().join("s2"), &published, &[old], &t.path().join("out2"));
    let fetch_chunks_ms = started.elapsed().as_millis();
    std::fs::write(r2.join(patch::list_path(&published.manifest)), list).unwrap();
    let started = std::time::Instant::now();
    let report = fetch_into(&r2, &t.path().join("s"), &published, &[old], &t.path().join("out"));
    let fetch_ms = started.elapsed().as_millis();
    let moved = report.patch_bytes + report.range_bytes + report.meta_bytes;
    let moved_chunks = chunks.range_bytes + chunks.meta_bytes;
    println!(
        "{}",
        serde_json::json!({
            "published": published, "publish_ms": publish_ms, "fetch_ms": fetch_ms, "fetch_chunks_only_ms": fetch_chunks_ms,
            "with_patches": report, "chunks_only": chunks,
            "moved": moved, "moved_chunks_only": moved_chunks,
            "pct_of_tree": 100.0 * moved as f64 / published.tree_bytes as f64,
            "pct_of_tree_chunks_only": 100.0 * moved_chunks as f64 / published.tree_bytes as f64,
        })
    );
}
