use super::*;

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn round_trip(codec: Codec) {
    let src = tempfile::tempdir().unwrap();
    let nm = src.path().join("node_modules");
    write(&nm.join("left-pad/index.js"), "module.exports = 1");
    write(&nm.join("left-pad/.npmrc"), "//registry.npmjs.org/:_authToken=secret");
    write(&nm.join("pkg/.env.local"), "TOKEN=secret");
    write(&nm.join(".cache/babel/x.json"), "{}");
    write(&nm.join(".bin/.keep"), "");
    write(&nm.join("from-git/.git/config"), "url = https://user:token@example.com/r");
    write(&nm.join(".yarn-integrity"), "{\"lockfileEntries\":{\"a\":\"https://r/a.tgz?token=x\"}}");
    let bare = nm.join("bare-db");
    write(&bare.join("HEAD"), "ref: refs/heads/main");
    write(&bare.join("FETCH_HEAD"), "abc https://user:token@example.com/r");
    write(&bare.join("objects/.keep"), "");
    write(&bare.join("refs/.keep"), "");
    #[cfg(unix)]
    std::os::unix::fs::symlink("../left-pad/index.js", nm.join(".bin/left-pad")).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::Permissions::from_mode(0o4755);
        std::fs::set_permissions(nm.join("left-pad/index.js"), mode).unwrap();
    }
    write(&src.path().join(".npmrc"), "outside the packed folder");

    let out = tempfile::tempdir().unwrap();
    let archive = out.path().join("a.tar");
    let packed = pack(src.path(), &["node_modules".into()], codec, &archive).unwrap();
    assert_eq!(packed.files, 2, "{packed:?}");
    let mut denied = packed.denied.clone();
    denied.sort();
    assert_eq!(
        denied,
        [
            "node_modules/.yarn-integrity",
            "node_modules/bare-db",
            "node_modules/from-git/.git",
            "node_modules/left-pad/.npmrc",
            "node_modules/pkg/.env.local",
        ]
    );

    let dest = tempfile::tempdir().unwrap();
    let unpacked = unpack(&archive, codec, dest.path(), &["node_modules".into()], true).unwrap();
    assert_eq!(unpacked.denied, 0);
    assert_eq!(unpacked.outside, 0);
    let got = dest.path().join("node_modules");
    assert_eq!(
        std::fs::read_to_string(got.join("left-pad/index.js")).unwrap(),
        "module.exports = 1"
    );
    assert!(!got.join("left-pad/.npmrc").exists());
    {
        // Execute bits survive the unpack; setuid does not.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(got.join("left-pad/index.js")).unwrap().permissions().mode();
        assert_eq!(mode & 0o7777, 0o755, "{mode:o}");
    }
    assert!(!got.join("pkg/.env.local").exists());
    assert!(!got.join("from-git/.git").exists());
    assert!(!got.join("bare-db").exists());
    assert!(!got.join(".cache").exists());
    assert!(!dest.path().join(".npmrc").exists());
    #[cfg(unix)]
    assert_eq!(
        std::fs::read_link(got.join(".bin/left-pad")).unwrap(),
        PathBuf::from("../left-pad/index.js")
    );
}

#[test]
fn gzip_round_trip_never_carries_credentials() {
    round_trip(Codec::Gzip);
}

#[test]
fn zstd_round_trip_never_carries_credentials() {
    if Codec::here() != Codec::Zstd {
        eprintln!("zstd is not installed here; the gzip test covers the archive");
        return;
    }
    round_trip(Codec::Zstd);
}

#[test]
fn unpack_never_writes_through_a_link_that_leaves_the_plan_folders() {
    let out = tempfile::tempdir().unwrap();
    let archive = out.path().join("a.tar.gz");
    {
        let gz = flate2::write::GzEncoder::new(
            File::create(&archive).unwrap(),
            flate2::Compression::fast(),
        );
        let mut b = tar::Builder::new(gz);
        let link = |name: &str, target: &str, kind: tar::EntryType| {
            let mut h = tar::Header::new_gnu();
            h.set_entry_type(kind);
            h.set_size(0);
            h.set_mode(0o777);
            h.set_path(name).unwrap();
            h.set_link_name(target).unwrap();
            h.set_cksum();
            h
        };
        // registry/cache -> ../bin, then a file through it: ~/.cargo/bin/cargo.
        let h = link("registry/cache", "../bin", tar::EntryType::Symlink);
        b.append(&h, &[][..]).unwrap();
        let h = link("registry/index/abs", "/etc", tar::EntryType::Symlink);
        b.append(&h, &[][..]).unwrap();
        let h = link("registry/index/hard", "bin/cargo", tar::EntryType::Link);
        b.append(&h, &[][..]).unwrap();
        // A link that stays inside the plan's folders is kept.
        let h = link("registry/index/ok", "../cache-ok", tar::EntryType::Symlink);
        b.append(&h, &[][..]).unwrap();
        let mut header = tar::Header::new_gnu();
        header.set_size(6);
        header.set_mode(0o644);
        header.set_cksum();
        b.append_data(&mut header, "registry/cache/cargo", &b"#!evil"[..]).unwrap();
        b.into_inner().unwrap().finish().unwrap();
    }
    let dest = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dest.path().join("bin")).unwrap();
    let allowed = ["registry/index".into(), "registry/cache".into(), "registry/cache-ok".into()];
    // The file entry then lands in a real registry/cache folder, never in bin/.
    // Into a fresh folder, a link that stays inside is kept.
    let unpacked = unpack(&archive, Codec::Gzip, dest.path(), &allowed, true).unwrap();
    assert_eq!(unpacked.outside, 3, "{unpacked:?}");
    assert!(!dest.path().join("bin/cargo").exists());
    assert!(!dest.path().join("registry/cache").is_symlink());
    assert!(!dest.path().join("registry/index/abs").exists());
    assert!(dest.path().join("registry/index/ok").is_symlink());
    // Merged into a shared cache, no link is written at all, so no chain of
    // them (a/b -> ../../cache, escape -> a/b/../../bin) can leave it.
    let shared = tempfile::tempdir().unwrap();
    let unpacked = unpack(&archive, Codec::Gzip, shared.path(), &allowed, false).unwrap();
    assert_eq!(unpacked.outside, 4, "{unpacked:?}");
    assert!(!shared.path().join("registry/index/ok").exists());
    assert!(shared.path().join("registry/cache/cargo").is_file());
}

#[test]
fn unpack_refuses_link_chains_and_writes_through_links() {
    let out = tempfile::tempdir().unwrap();
    let archive = out.path().join("a.tar.gz");
    {
        let gz = flate2::write::GzEncoder::new(
            File::create(&archive).unwrap(),
            flate2::Compression::fast(),
        );
        let mut b = tar::Builder::new(gz);
        let link = |name: &str, target: &str| {
            let mut h = tar::Header::new_gnu();
            h.set_entry_type(tar::EntryType::Symlink);
            h.set_size(0);
            h.set_mode(0o777);
            h.set_path(name).unwrap();
            h.set_link_name(target).unwrap();
            h.set_cksum();
            h
        };
        // anchor -> . stays inside; alias -> anchor/../.env reads the project's .env.
        b.append(&link("node_modules/anchor", "."), &[][..]).unwrap();
        b.append(&link("node_modules/alias", "anchor/../x"), &[][..]).unwrap();
        // A link nested under a link: its `..` climbs from where anchor points.
        b.append(&link("node_modules/anchor/up", "../y"), &[][..]).unwrap();
        let mut header = tar::Header::new_gnu();
        header.set_size(2);
        header.set_mode(0o644);
        header.set_cksum();
        b.append_data(&mut header, "node_modules/anchor/z", &b"hi"[..]).unwrap();
        b.append(&link("node_modules/.bin/ok", "../pkg/bin.js"), &[][..]).unwrap();
        b.into_inner().unwrap().finish().unwrap();
    }
    let dest = tempfile::tempdir().unwrap();
    let unpacked =
        unpack(&archive, Codec::Gzip, dest.path(), &["node_modules".into()], true).unwrap();
    assert_eq!(unpacked.outside, 3, "{unpacked:?}");
    let nm = dest.path().join("node_modules");
    assert!(nm.join("anchor").is_symlink());
    assert!(!nm.join("alias").exists() && !nm.join("alias").is_symlink());
    assert!(!nm.join("up").is_symlink() && !nm.join("z").exists());
    assert!(nm.join(".bin/ok").is_symlink());
}

#[test]
fn npm_index_entries_with_credential_headers_are_dropped() {
    let src = tempfile::tempdir().unwrap();
    let index = src.path().join("_cacache/index-v5/ab/cd/abcdef");
    let public =
        "1a2b\t{\"key\":\"make-fetch-happen:request-cache:https://registry.npmjs.org/a\"}\n";
    let private = "3c4d\t{\"metadata\":{\"reqHeaders\":{\"authorization\":\"Bearer npm_x\"}}}\n";
    write(&index, &format!("{public}{private}"));
    write(&src.path().join("_cacache/content-v2/sha512/aa/bb"), "tarball");
    let out = tempfile::tempdir().unwrap();
    let archive = out.path().join("a.tar");
    let packed = pack(src.path(), &["_cacache".into()], Codec::Gzip, &archive).unwrap();
    assert_eq!(packed.denied, ["_cacache/index-v5/ab/cd/abcdef"]);
    let dest = tempfile::tempdir().unwrap();
    unpack(&archive, Codec::Gzip, dest.path(), &["_cacache".into()], false).unwrap();
    let got = std::fs::read_to_string(dest.path().join("_cacache/index-v5/ab/cd/abcdef")).unwrap();
    assert_eq!(got, public);
    assert!(dest.path().join("_cacache/content-v2/sha512/aa/bb").is_file());
}

#[test]
fn npm_files_naming_authenticated_urls_are_left_out() {
    assert!(url_with_userinfo(b"\"resolved\":\"https://u:p@npm.example.com/a.tgz\""));
    assert!(url_with_userinfo(b"x https://token@host/a"));
    assert!(!url_with_userinfo(b"https://registry.npmjs.org/@scope/a/-/a.tgz"));
    assert!(!url_with_userinfo(b"mailto me@x.com, https://x.com/a@b"));
    assert!(url_with_userinfo(b"https://r.org/pkg.tgz?token=SECRET"));
    assert!(url_with_userinfo(b"https://s3/x.tgz?X-Amz-Signature=abc&v=1"));
    assert!(!url_with_userinfo(b"https://r.org/pkg.tgz?version=1.2&format=tgz"));
    let src = tempfile::tempdir().unwrap();
    write(
        &src.path().join("_cacache/content-v2/sha512/aa/pub"),
        "{\"dist\":\"https://r.org/a.tgz\"}",
    );
    write(
        &src.path().join("_cacache/content-v2/sha512/aa/priv"),
        "{\"dist\":\"https://u:p@r.org/a.tgz\"}",
    );
    let out = tempfile::tempdir().unwrap();
    let archive = out.path().join("a.tar");
    let packed = pack(src.path(), &["_cacache".into()], Codec::Gzip, &archive).unwrap();
    assert_eq!(packed.denied, ["_cacache/content-v2/sha512/aa/priv"]);
    assert_eq!(packed.files, 1);
}

#[test]
fn unpack_writes_only_the_plan_folders_never_credentials_and_refuses_escapes() {
    let out = tempfile::tempdir().unwrap();
    let archive = out.path().join("a.tar.gz");
    {
        let gz = flate2::write::GzEncoder::new(
            File::create(&archive).unwrap(),
            flate2::Compression::fast(),
        );
        let mut b = tar::Builder::new(gz);
        let mut header = tar::Header::new_gnu();
        header.set_size(6);
        header.set_mode(0o644);
        header.set_cksum();
        b.append_data(&mut header.clone(), "node_modules/x/.npmrc", &b"secret"[..]).unwrap();
        b.append_data(&mut header.clone(), "node_modules/x/ok.js", &b"okay!!"[..]).unwrap();
        b.append_data(&mut header, "bin/cargo", &b"#!evil"[..]).unwrap();
        b.into_inner().unwrap().finish().unwrap();
    }
    let dest = tempfile::tempdir().unwrap();
    let unpacked =
        unpack(&archive, Codec::Gzip, dest.path(), &["node_modules".into()], true).unwrap();
    assert_eq!(unpacked, Unpacked { entries: 1, denied: 1, outside: 1 });
    assert!(!dest.path().join("bin/cargo").exists());
    assert!(!dest.path().join("node_modules/x/.npmrc").exists());
    assert!(dest.path().join("node_modules/x/ok.js").exists());
    assert!(pack(dest.path(), &["../x".into()], Codec::Gzip, &out.path().join("b")).is_err());
}

#[test]
fn credential_names() {
    for name in [
        ".npmrc",
        ".NPMRC",
        ".env",
        ".envrc",
        ".env.production",
        "credentials.toml",
        "credentials-prod.json",
        ".yarnrc.yml",
        ".yarnrc.local",
        ".npmrc.bak",
    ] {
        assert!(denied(name), "{name}");
    }
    assert!(denied(".git"));
    for name in ["index.js", "environment.js", "env", "credentials-helper.js", ".gitignore"] {
        assert!(!denied(name), "{name}");
    }
}
