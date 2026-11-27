//! A published tree is fetched bit-exact from Range GETs, reading only what the held tree lacks.

use cmux_cas::Store;
use cmux_cas::fetch::{DirSource, Report, fetch};
use cmux_cas::publish::publish;
use std::path::Path;

fn noise(n: usize, seed: u64) -> Vec<u8> {
    let mut s = seed | 1;
    (0..n)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s as u8
        })
        .collect()
}

fn write(root: &Path, path: &str, bytes: &[u8]) {
    let p = root.join(path);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, bytes).unwrap();
}

#[test]
fn fetch_reads_only_what_the_held_tree_lacks() {
    let t = tempfile::tempdir().unwrap();
    let (v1, v2, r2) = (t.path().join("v1"), t.path().join("v2"), t.path().join("r2"));
    let app = noise(3 << 20, 1);
    write(&v1, "agent-pane/app-1.js", &app);
    write(&v1, "agent-pane/index.html", b"<html>1</html>");
    let mut app2 = app;
    app2.splice(1 << 20..1 << 20, noise(3000, 7));
    write(&v2, "agent-pane/app-2.js", &app2);
    write(&v2, "agent-pane/index.html", b"<html>2</html>");
    let published = publish(&v2, &r2).unwrap();

    // Cold: no store, nothing held: the whole pack.
    let cold = t.path().join("cold");
    let report = fetch(
        &mut DirSource(r2.clone()),
        &Store::new(t.path().join("s1")),
        &published.manifest,
        &published.pack,
        &[],
        &cold,
    )
    .unwrap();
    assert_eq!(report.range_bytes, published.pack_bytes);
    assert_eq!(std::fs::read(cold.join("agent-pane/app-2.js")).unwrap(), app2);

    // Warm: the app holds v1's tree on disk.
    let warm = t.path().join("warm");
    let report: Report = fetch(
        &mut DirSource(r2.clone()),
        &Store::new(t.path().join("s2")),
        &published.manifest,
        &published.pack,
        std::slice::from_ref(&v1),
        &warm,
    )
    .unwrap();
    assert!(report.reused > 0);
    assert!(report.range_bytes * 5 < published.pack_bytes, "{report:?} {published:?}");
    assert_eq!(std::fs::read(warm.join("agent-pane/app-2.js")).unwrap(), app2);
    assert_eq!(std::fs::read(warm.join("agent-pane/index.html")).unwrap(), b"<html>2</html>");

    // A pack byte flipped on the server is refused.
    let pack = r2.join(cmux_cas::publish::pack_path(&published.pack));
    let mut bytes = std::fs::read(&pack).unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 1;
    std::fs::write(&pack, bytes).unwrap();
    assert!(
        fetch(
            &mut DirSource(r2),
            &Store::new(t.path().join("s3")),
            &published.manifest,
            &published.pack,
            &[],
            &t.path().join("bad"),
        )
        .is_err()
    );
}
