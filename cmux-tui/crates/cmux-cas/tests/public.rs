use cmux_cas::Id;
use cmux_cas::cold::{Body, ColdManifest};
use cmux_cas::dedup::{Options, measure};
use cmux_cas::public::{Algo, Checksum, Kind, Public, Source};
use sha2::Digest as _;
use std::collections::BTreeMap;

fn noise(seed: u64, n: usize) -> Vec<u8> {
    let mut x = seed;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

fn sha256(b: &[u8]) -> Checksum {
    let h = sha2::Sha256::digest(b);
    Checksum::new(Algo::Sha256, &h.iter().map(|b| format!("{b:02x}")).collect::<String>()).unwrap()
}

fn src(name: &str, b: &[u8]) -> Source {
    Source { kind: Kind::Crate, name: name.into(), version: "1.0.0".into(), checksum: sha256(b) }
}

fn files(items: &[(&str, &[u8])]) -> BTreeMap<String, (Vec<u8>, bool)> {
    items.iter().map(|(p, b)| ((*p).to_string(), (b.to_vec(), false))).collect()
}

#[test]
fn a_public_file_becomes_a_ref_and_a_private_file_stays_tenant_keyed() {
    let dir = tempfile::tempdir().unwrap();
    let public = Public::new(dir.path());
    let crate_bytes = noise(1, 1 << 20);
    public.publish_file(&src("serde", &crate_bytes), "serde/lib.rs", &crate_bytes, false).unwrap();
    let index = public.index().unwrap();

    // Two tenants hold the same private bytes that no public source states.
    let private = noise(2, 1 << 20);
    let (key_a, key_b) = ([1u8; 32], [2u8; 32]);
    let tree = files(&[("src/vendored.rs", &crate_bytes), ("secret.env", &private)]);
    let (a, stats_a) = ColdManifest::build(&tree, &key_a, &index, |_, _| Ok(())).unwrap();
    let (b, _) = ColdManifest::build(&tree, &key_b, &index, |_, _| Ok(())).unwrap();

    let by = |m: &ColdManifest, p: &str| m.files.iter().find(|f| f.path == p).unwrap().clone();
    // The public file is a ref to public ids, identical for both tenants, and costs no chunk.
    let (pa, pb) = (by(&a, "src/vendored.rs"), by(&b, "src/vendored.rs"));
    assert!(matches!(pa.body, Body::Public { .. }));
    assert_eq!(pa, pb);
    assert_eq!(pa.hash, Id::of(&crate_bytes));
    assert_eq!((stats_a.ref_files, stats_a.tenant_files), (1, 1));
    assert_eq!(stats_a.tenant_chunk_bytes, private.len() as u64);

    // The private file is tenant-keyed: no id in common across tenants, none a public id.
    let (xa, xb) = (by(&a, "secret.env"), by(&b, "secret.env"));
    assert!(matches!(xa.body, Body::Tenant { .. }));
    assert_ne!(xa.hash, xb.hash);
    assert_ne!(xa.hash, Id::of(&private));
    let (ca, cb) = (xa.body.chunks(), xb.body.chunks());
    assert_eq!(ca.len(), cb.len());
    for (u, v) in ca.iter().zip(cb) {
        assert_ne!(u.id, v.id);
        assert!(!index.has(&u.id) && !index.has(&v.id));
    }
    assert!(a.tenant_chunks().iter().all(|id| !b.tenant_chunks().contains(id)));
}

#[test]
fn a_private_file_is_not_public_just_because_it_is_in_a_tenant() {
    // An empty index: nothing is public, so nothing is a ref, whatever the bytes.
    let index = cmux_cas::public::PublicIndex::default();
    let tree = files(&[("a", &noise(3, 100_000))]);
    let (m, s) = ColdManifest::build(&tree, &[9u8; 32], &index, |_, _| Ok(())).unwrap();
    assert_eq!(s.ref_files, 0);
    assert!(matches!(m.files[0].body, Body::Tenant { .. }));
}

#[test]
fn nothing_unchecked_enters_the_public_tier() {
    let dir = tempfile::tempdir().unwrap();
    let public = Public::new(dir.path());
    let good = noise(4, 50_000);
    let mut forged = good.clone();
    forged[7] ^= 1;
    let e = public.publish_file(&src("x", &good), "x", &forged, false).unwrap_err();
    assert!(e.to_string().contains("checksum"), "{e}");
    assert!(public.entries().unwrap().is_empty());
    assert!(public.index().unwrap().is_empty());
    // A bad digest length is refused before any bytes are looked at.
    assert!(Checksum::new(Algo::Sha256, "abcd").is_err());
}

#[test]
fn a_verified_archive_publishes_and_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let public = Public::new(dir.path());
    let mut tarball = Vec::new();
    {
        let gz = flate2::write::GzEncoder::new(&mut tarball, flate2::Compression::fast());
        let mut t = tar::Builder::new(gz);
        for (p, b) in
            [("c-1.0.0/src/lib.rs", noise(5, 200_000)), ("c-1.0.0/Cargo.toml", b"x".to_vec())]
        {
            let mut h = tar::Header::new_gnu();
            h.set_size(b.len() as u64);
            h.set_mode(0o644);
            h.set_cksum();
            t.append_data(&mut h, p, &b[..]).unwrap();
        }
        t.into_inner().unwrap().finish().unwrap();
    }
    let s = src("c", &tarball);
    let first = public.publish_archive(&s, &tarball, 0).unwrap();
    assert_eq!(first.files, 2);
    assert!(!first.already_published);
    let again = public.publish_archive(&s, &tarball, 0).unwrap();
    assert!(again.already_published);
    assert_eq!(again.new_chunks, 0);
    assert_eq!(public.entries().unwrap().len(), 1);
}

#[test]
fn the_dedup_measurement_reports_the_physical_drop() {
    let pubdir = tempfile::tempdir().unwrap();
    let public = Public::new(pubdir.path());
    let lib = noise(6, 2 << 20);
    public.publish_file(&src("lib", &lib), "lib.so", &lib, false).unwrap();

    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("lib.so"), &lib).unwrap();
    std::fs::write(root.path().join("mine"), noise(7, 1 << 20)).unwrap();
    let opts = Options { public: Some(public.index().unwrap().prefixes()), ..Options::default() };
    let r = measure(&[("r".into(), root.path().into())], &opts);
    assert_eq!(r.public_ref_files, 1);
    assert_eq!(r.public_ref_file_bytes, lib.len() as u64);
    assert_eq!(r.public_chunk_bytes, lib.len() as u64);
    assert_eq!(r.physical_after_public, r.physical - lib.len() as u64);
}
