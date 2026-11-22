//! RED (security): every way out of the roots is `fs.permission_denied`,
//! and a symlink that stays inside works.

use std::fs;
use std::os::unix::fs::symlink;

use serde_json::json;

use super::tests::TempRoot;
use super::*;

fn denied(service: &FsService, cmd: &str, params: serde_json::Value) {
    assert_eq!(
        service.call("owner", cmd, params.clone()),
        Err(FsError::PermissionDenied),
        "{cmd} {params}"
    );
}

/// Every op that takes `path`, aimed at `path`.
fn every_op_is_denied(service: &FsService, path: &str) {
    denied(service, "fs.stat", json!({ "path": path }));
    denied(service, "fs.list", json!({ "path": path, "limit": 10 }));
    denied(service, "fs.read", json!({ "path": path, "offset": 0, "max_bytes": 10 }));
    denied(service, "fs.write", json!({ "path": path, "text": "x", "mode": "overwrite" }));
    denied(service, "fs.mkdir", json!({ "path": path, "name": "made" }));
    denied(service, "fs.delete", json!({ "paths": [path], "permanent": true }));
}

#[test]
fn dot_dot_in_a_request_is_refused() {
    let root = TempRoot::new("dotdot");
    root.file("a/x.txt", b"x");
    let service = root.service();
    every_op_is_denied(&service, &format!("{}/a/../a/x.txt", root.path.display()));
    every_op_is_denied(&service, &format!("{}/..", root.path.display()));
    every_op_is_denied(&service, &format!("{}/./a", root.path.display()));
}

#[test]
fn an_absolute_path_outside_the_roots_is_refused() {
    let root = TempRoot::new("abs");
    let outside = TempRoot::new("abs-outside");
    outside.file("secret.txt", b"secret");
    let service = root.service();
    every_op_is_denied(&service, &outside.at("secret.txt"));
    every_op_is_denied(&service, "/");
    // A sibling whose name extends the root's name is not inside it.
    let sibling = format!("{}-sibling", root.path.display());
    fs::create_dir_all(&sibling).unwrap();
    every_op_is_denied(&service, &format!("{sibling}/x"));
    let _ = fs::remove_dir_all(sibling);
    assert_eq!(fs::read(outside.path.join("secret.txt")).unwrap(), b"secret");
}

#[test]
fn a_symlink_out_of_the_root_is_refused_in_the_middle_and_at_the_end() {
    let root = TempRoot::new("linkout");
    let outside = TempRoot::new("linkout-outside");
    outside.file("secret.txt", b"secret");
    symlink(&outside.path, root.path.join("out")).unwrap();
    symlink(outside.path.join("secret.txt"), root.path.join("secret-link")).unwrap();
    let service = root.service();
    every_op_is_denied(&service, &root.at("out/secret.txt"));
    every_op_is_denied(&service, &root.at("out/new.txt"));
    denied(
        &service,
        "fs.read",
        json!({ "path": root.at("secret-link"), "offset": 0, "max_bytes": 9 }),
    );
    denied(
        &service,
        "fs.write",
        json!({ "path": root.at("secret-link"), "text": "pwned", "mode": "overwrite" }),
    );
    denied(&service, "fs.list", json!({ "path": root.at("out"), "limit": 10 }));
    assert_eq!(fs::read(outside.path.join("secret.txt")).unwrap(), b"secret");
    assert_eq!(fs::read_dir(&outside.path).unwrap().count(), 1, "nothing was created outside");
}

#[test]
fn a_relative_symlink_that_climbs_out_is_refused() {
    let root = TempRoot::new("climb");
    let outside = TempRoot::new("climb-outside");
    outside.file("secret.txt", b"secret");
    fs::create_dir(root.path.join("a")).unwrap();
    let up = format!("../../{}", outside.path.file_name().unwrap().to_str().unwrap());
    symlink(&up, root.path.join("a/up")).unwrap();
    symlink("..", root.path.join("parent")).unwrap();
    let service = root.service();
    every_op_is_denied(&service, &root.at("a/up/secret.txt"));
    every_op_is_denied(&service, &root.at("parent/x"));
    assert_eq!(fs::read(outside.path.join("secret.txt")).unwrap(), b"secret");
}

#[test]
fn a_symlink_loop_is_refused() {
    let root = TempRoot::new("loop");
    symlink("b", root.path.join("a")).unwrap();
    symlink("a", root.path.join("b")).unwrap();
    symlink("self/x", root.path.join("self")).unwrap();
    let service = root.service();
    denied(&service, "fs.read", json!({ "path": root.at("a"), "offset": 0, "max_bytes": 9 }));
    denied(&service, "fs.list", json!({ "path": root.at("self"), "limit": 10 }));
}

#[test]
fn symlinks_that_stay_inside_work() {
    let root = TempRoot::new("inside");
    root.file("real/file.txt", b"inside");
    symlink("real", root.path.join("alias")).unwrap();
    symlink(root.path.join("real/file.txt"), root.path.join("abs-link")).unwrap();
    fs::create_dir(root.path.join("deep")).unwrap();
    symlink("../real/file.txt", root.path.join("deep/up-link")).unwrap();
    let service = root.service();
    for path in ["alias/file.txt", "abs-link", "deep/up-link"] {
        let read = service
            .call(
                "owner",
                "fs.read",
                json!({ "path": root.at(path), "offset": 0, "max_bytes": 99 }),
            )
            .unwrap();
        assert_eq!(read["text"], "inside", "{path}");
    }
    let stat = service.call("owner", "fs.stat", json!({ "path": root.at("alias") })).unwrap();
    assert_eq!(stat["kind"], "symlink");
    assert_eq!(stat["target_kind"], "dir");
    let listing =
        service.call("owner", "fs.list", json!({ "path": root.at("alias"), "limit": 10 })).unwrap();
    assert_eq!(listing["entries"][0]["name"], "file.txt");
    // A write through an inside link replaces the target, not the link.
    service
        .call(
            "owner",
            "fs.write",
            json!({ "path": root.at("abs-link"), "text": "new", "mode": "overwrite" }),
        )
        .unwrap();
    assert_eq!(fs::read(root.path.join("real/file.txt")).unwrap(), b"new");
    assert!(fs::symlink_metadata(root.path.join("abs-link")).unwrap().file_type().is_symlink());
}

#[test]
fn a_listing_reports_no_target_for_a_link_that_leaves() {
    let root = TempRoot::new("listlink");
    let outside = TempRoot::new("listlink-outside");
    symlink(&outside.path, root.path.join("out")).unwrap();
    let listing = root
        .service()
        .call("owner", "fs.list", json!({ "path": root.at(""), "limit": 10 }))
        .unwrap();
    assert_eq!(listing["entries"][0]["kind"], "symlink");
    assert!(listing["entries"][0].get("target_kind").is_none());
}

/// RED (security): a folder that becomes a symlink between the look and
/// the open is not entered. The walk opens each folder with `O_NOFOLLOW`
/// from its parent's descriptor; this checks that primitive directly.
#[test]
fn a_folder_swapped_for_a_symlink_is_not_entered() {
    let root = TempRoot::new("swap");
    let outside = TempRoot::new("swap-outside");
    outside.file("secret.txt", b"secret");
    fs::create_dir(root.path.join("d")).unwrap();
    let root_fd = sys::open_root(&root.path).unwrap();
    // The look said "folder"...
    let look = sys::lstat_at(std::os::fd::AsFd::as_fd(&root_fd), "d").unwrap();
    assert_eq!(entry::Meta::of(&look).kind, EntryKind::Dir);
    // ...then it is swapped before the open.
    fs::remove_dir(root.path.join("d")).unwrap();
    symlink(&outside.path, root.path.join("d")).unwrap();
    let opened = sys::open_dir_at(std::os::fd::AsFd::as_fd(&root_fd), "d");
    let error = FsError::from(opened.expect_err("O_NOFOLLOW refuses the swapped symlink"));
    assert!(matches!(error, FsError::PermissionDenied | FsError::NotADirectory), "{error:?}");
}

#[test]
fn a_configured_spelling_of_a_root_is_accepted() {
    let root = TempRoot::new("spell");
    root.file("x.txt", b"x");
    let alias = std::env::temp_dir().join(format!("cmux-fs-alias-{}", sys::random_hex(6)));
    symlink(&root.path, &alias).unwrap();
    let service = FsService::new(Roots::new([alias.clone()]));
    let path = format!("{}/x.txt", alias.display());
    let read = service
        .call("owner", "fs.read", json!({ "path": path, "offset": 0, "max_bytes": 9 }))
        .unwrap();
    assert_eq!(read["text"], "x");
    let _ = fs::remove_file(alias);
}

/// Review fix: the file system root is never a root (a daemon with
/// `HOME=/` must not serve the whole machine).
#[test]
fn the_file_system_root_is_never_a_root() {
    assert!(Roots::new([std::path::PathBuf::from("/")]).is_empty());
}
