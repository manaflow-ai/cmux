use super::*;

const ROOT: &str = "1 0 8:1 / / rw - ext4 root rw\n";

fn guarded_aliases(trees: &[(&Path, u64, bool)], info: &str) -> Vec<String> {
    guarded_aliases_with(trees, info, |p| Ok(p.to_path_buf()), |_| Ok(true))
}

fn overlay_info(options: &str) -> String {
    format!("{ROOT}2 1 0:42 / /mnt/leak rw - overlay overlay {options}\n")
}

#[test]
fn regression_sys_autofs_is_refused() {
    let info = format!("{ROOT}2 1 0:42 / /sys/kernel/debug rw - autofs map rw\n");
    let reasons = guarded_aliases(&[], &info);
    assert!(reasons.iter().any(|r| r.contains("autofs")), "{reasons:?}");
}

#[test]
fn regression_overlay_plus_options_are_layers() {
    for key in ["lowerdir+", "datadir+"] {
        let info = overlay_info(&format!("{key}=/home/u/.ssh"));
        let reasons = guarded_aliases_with(
            &[(Path::new("/home/u/.ssh"), 1, false)],
            &info,
            |p| Ok(p.to_path_buf()),
            |_| Ok(true),
        );
        assert!(reasons.iter().any(|r| r.contains("overlay layer")), "{key}: {reasons:?}");
    }
    assert_eq!(
        overlay_layers("lowerdir+=/a:b,datadir+=/c:d").unwrap(),
        [PathBuf::from("/a:b"), PathBuf::from("/c:d")]
    );
}

#[test]
fn regression_unknown_overlay_layer_syntax_is_refused() {
    for option in ["fooodir=/secret", "fooodir+=/secret"] {
        let reasons =
            guarded_aliases_with(&[], &overlay_info(option), |p| Ok(p.to_path_buf()), |_| Ok(true));
        assert!(reasons.iter().any(|r| r.contains("unknown overlay")), "{reasons:?}");
    }
}

#[test]
fn reachable_overlay_non_layer_options_are_accepted() {
    let info = overlay_info("lowerdir=/var/lib/x,redirect_dir=on,index=on,metacopy=on,xino=auto");
    let reasons = guarded_aliases_with(
        &[(Path::new("/home/u/.ssh"), 1, false)],
        &info,
        |p| Ok(p.to_path_buf()),
        |_| Ok(true),
    );
    assert!(reasons.is_empty(), "{reasons:?}");
}

#[test]
fn regression_overlay_layer_symlink_is_resolved() {
    let reasons = guarded_aliases_with(
        &[(Path::new("/home/u/.ssh"), 1, false)],
        &overlay_info("lowerdir=/srv/ssh-layer"),
        |p| {
            assert_eq!(p, Path::new("/srv/ssh-layer"));
            Ok(PathBuf::from("/home/u/.ssh"))
        },
        |_| Ok(true),
    );
    assert!(reasons.iter().any(|r| r.contains("overlay layer /home/u/.ssh")), "{reasons:?}");
}

#[test]
fn regression_unreachable_overlay_is_skipped() {
    let reasons = guarded_aliases_with(
        &[(Path::new("/home/u/.ssh"), 1, false)],
        &overlay_info("lowerdir=/home/u/.ssh"),
        |_| panic!("unreachable overlay layers must not be resolved"),
        |p| {
            assert_eq!(p, Path::new("/mnt/leak"));
            Ok(false)
        },
    );
    assert!(reasons.is_empty(), "{reasons:?}");
}

#[test]
fn regression_tmpfs_does_not_overlap_unrelated_host_layer() {
    let info =
        format!("{}3 1 0:43 / /tmp rw - tmpfs tmpfs rw\n", overlay_info("lowerdir=/var/lib/x"));
    let reasons = guarded_aliases_with(
        &[(Path::new("/tmp"), 3, true)],
        &info,
        |p| Ok(p.to_path_buf()),
        |_| Ok(true),
    );
    assert!(reasons.is_empty(), "{reasons:?}");
}

#[test]
fn real_overlay_layer_symlink_is_canonicalized() {
    let root = std::env::temp_dir().join(format!("acpmux-layer-{}", uuid::Uuid::now_v7()));
    fs::create_dir(&root).unwrap();
    let root = fs::canonicalize(root).unwrap();
    let secret = root.join("secret");
    fs::create_dir(&secret).unwrap();
    let link = root.join("layer");
    std::os::unix::fs::symlink(&secret, &link).unwrap();
    let point = root.join("mount");
    fs::create_dir(&point).unwrap();
    let info = overlay_info(&format!("lowerdir={}", link.display()))
        .replace("/mnt/leak", point.to_str().unwrap());
    let reasons = super::guarded_aliases(&[(&secret, 1, false)], &info);
    fs::remove_dir_all(root).unwrap();
    assert!(
        reasons.iter().any(|r| r.contains(&format!("overlay layer {}", secret.display()))),
        "{reasons:?}"
    );
    eprintln!("passed: overlay layer symlink resolved through the kernel");
}

#[test]
fn regression_hidden_mount_cannot_disguise_containing_mount() {
    let info = format!(
        "{ROOT}2 1 0:42 / /mnt/meta/hooks rw - tmpfs tmpfs rw\n3 1 8:1 /home/u/repo/.git /mnt/meta rw - ext4 root rw\n"
    );
    let reasons = guarded_aliases(&[(Path::new("/mnt/meta/hooks"), 3, true)], &info);
    assert!(reasons.iter().any(|r| r.contains("/home/u/repo/.git/hooks")), "{reasons:?}");
}

#[test]
fn regression_overlay_exports_writable_subtree() {
    let info = format!(
        "{ROOT}2 1 0:42 / /home/u/victim/.git/hooks rw - overlay overlay upperdir=/home/u/work/cache\n"
    );
    let reasons = guarded_aliases(&[(Path::new("/home/u/work"), 1, true)], &info);
    assert!(reasons.iter().any(|r| r.contains("overlay layer")), "{reasons:?}");
}

#[test]
fn regression_protected_descendant_filesystem_is_guarded() {
    let info = format!(
        "{ROOT}2 1 0:42 / /home/u/.ssh/keys rw - tmpfs tmpfs rw\n3 1 0:42 / /mnt/leak rw - tmpfs tmpfs rw\n"
    );
    let reasons = guarded_aliases(&[(Path::new("/home/u/.ssh"), 1, false)], &info);
    assert!(reasons.iter().any(|r| r.contains("/mnt/leak")), "{reasons:?}");
}

#[test]
fn regression_outside_autofs_is_refused() {
    let info = format!("{ROOT}2 1 0:42 / /home/u/victim/.git rw - autofs map rw\n");
    let reasons = guarded_aliases(&[(Path::new("/home/u/work"), 1, true)], &info);
    assert!(reasons.iter().any(|r| r.contains("autofs")), "{reasons:?}");
}

// Copied from a real Ubuntu host's /proc/self/mountinfo (snapd installed).
const SNAPD_NS: &str = "34 1 0:29 / /run rw,nosuid,nodev,noexec,relatime - tmpfs tmpfs rw,size=6349032k,mode=755,inode64
1190 34 0:29 /snapd/ns /run/snapd/ns rw,nosuid,nodev - tmpfs tmpfs rw,size=6349028k,nr_inodes=819200,mode=755,inode64
4043 1190 0:5 mnt:[4026533090] /run/snapd/ns/snapd-desktop-integration.mnt rw - nsfs nsfs rw
6714 1190 0:5 mnt:[4026532813] /run/snapd/ns/firmware-updater.mnt rw - nsfs nsfs rw
";

#[test]
fn regression_snapd_nsfs_mounts_are_accepted() {
    let info = format!("{ROOT}{SNAPD_NS}");
    assert_eq!(parse_mountinfo(&info).map(|m| m.len()), Ok(5));
    assert!(guarded_aliases(&[], &info).is_empty());
    let trees = [
        (Path::new("/home/u/repo"), 1, true),
        (Path::new("/home/u/.ssh"), 1, false),
        (Path::new("/run/snapd/ns"), 1190, false),
    ];
    let reasons = guarded_aliases(&trees, &info);
    assert!(reasons.is_empty(), "{reasons:?}");
    // Same namespace bound twice: still no host path alias.
    let twice = info.replace("mnt:[4026532813]", "mnt:[4026533090]");
    assert!(guarded_aliases(&trees, &twice).is_empty());
}

#[test]
fn nsfs_mounts_keep_the_guards_that_apply() {
    let info = format!("{ROOT}{SNAPD_NS}");
    let reasons = guarded_aliases(&[(Path::new("/run/snapd/ns"), 1190, true)], &info);
    assert!(reasons.iter().any(|r| r.contains("non-local filesystem nsfs")), "{reasons:?}");
    let ns = Path::new("/run/snapd/ns/firmware-updater.mnt");
    let reasons = guarded_aliases(&[(ns, 6714, false)], &info);
    assert!(reasons.iter().any(|r| r.contains("namespace file mount")), "{reasons:?}");
    let trees = [(Path::new("/run/snapd"), 34, false)];
    assert!(guarded_aliases(&trees, &info).is_empty());
    let leak = format!("{info}7 1 0:29 /snapd /mnt/leak rw - tmpfs tmpfs rw\n");
    let reasons = guarded_aliases(&trees, &leak);
    assert!(reasons.contains(&"/run/snapd is also visible at /mnt/leak".into()), "{reasons:?}");
}

#[test]
fn regression_non_path_roots_outside_nsfs_are_refused() {
    for line in [
        "2 1 0:42 mnt:[4026533090] /mnt/x rw - tmpfs tmpfs rw",
        "2 1 8:1 relative/root /mnt/x rw - ext4 root rw",
        "2 1 0:5 mnt:[4026533090] relative/point rw - nsfs nsfs rw",
        "2 1 0:5 mnt:[] /mnt/x rw - nsfs nsfs rw",
        "2 1 0:5 mnt:[12a] /mnt/x rw - nsfs nsfs rw",
        "2 1 0:5 :[12] /mnt/x rw - nsfs nsfs rw",
        "2 1 0:5 mnt:[12]x /mnt/x rw - nsfs nsfs rw",
        "2 1 0:5 Mnt:[12] /mnt/x rw - nsfs nsfs rw",
        "2 1 0:5 ../mnt:[12] /mnt/x rw - nsfs nsfs rw",
        "2 1 0:5 /../x /mnt/x rw - nsfs nsfs rw",
    ] {
        let reasons = guarded_aliases(&[], &format!("{ROOT}{line}\n"));
        assert_eq!(reasons, ["invalid mountinfo path"], "{line}");
    }
}

#[test]
fn real_fdinfo_resolves_root_mount_id() {
    let id = resolved_mount_id(Path::new("/")).unwrap();
    let info = fs::read_to_string("/proc/self/mountinfo").unwrap();
    let mounts = parse_mountinfo(&info).unwrap();
    assert!(mounts.iter().any(|m| m.id == id && m.point == Path::new("/")));
    eprintln!("passed: fdinfo resolved / to mount ID {id}");
}

#[test]
fn guarded_views_acceptance_matrix() {
    for (tree, id, info) in [
            ("/home/u/repo", 1, ROOT.to_owned()),
            ("/home/u/repo", 1, "1 0 0:42 /@home /home rw - btrfs root rw\n".into()),
            ("/home/u/repo", 1, "1 0 0:42 /@home /home rw - btrfs root rw\n2 0 0:42 /@other /other rw - btrfs root rw\n".into()),
            ("/home/u/work", 1, format!("{ROOT}2 1 8:1 /home/u/other /mnt/o rw - ext4 root rw\n")),
            (
                "/home/u/work",
                1,
                format!("{ROOT}2 1 8:1 /home/u/work/sub /home/u/work/sub rw - ext4 root rw\n"),
            ),
            ("/tmp", 2, format!("{ROOT}2 1 0:42 / /tmp rw - tmpfs tmpfs rw\n")),
            ("/work", 1, format!("{ROOT}2 1 0:42 / /work/cache rw - tmpfs tmpfs rw\n")),
            ("/work", 1, format!("{ROOT}2 1 0:42 / /proc/sys/fs/binfmt_misc rw - autofs map rw\n")),
            (
                "/work",
                1,
                format!("{ROOT}2 1 0:42 / /elsewhere rw - overlay overlay lowerdir=/a::/b\n"),
            ),
        ] {
            let reasons = guarded_aliases(&[(Path::new(tree), id, true)], &info);
            assert!(reasons.is_empty(), "{info}: {reasons:?}");
        }
}

#[test]
fn hidden_descendants_are_dropped_but_visible_children_remain() {
    let info = format!(
        "{ROOT}2 1 0:42 / /guard/a/keys rw - tmpfs tmpfs rw\n3 1 0:43 / /guard/a rw - tmpfs tmpfs rw\n4 1 0:42 / /mnt/leak rw - tmpfs tmpfs rw\n"
    );
    let trees = [(Path::new("/guard"), 1, false)];
    assert!(guarded_aliases(&trees, &info).is_empty());
    // Reparenting keys into the overmount makes the previously hidden
    // filesystem reachable, so its external alias must now refuse.
    let visible = info.replace("2 1 0:42", "2 3 0:42");
    let reasons = guarded_aliases(&trees, &visible);
    assert!(reasons.iter().any(|r| r.contains("/mnt/leak")), "{reasons:?}");
}

#[test]
fn missing_mount_ids_and_overlay_layer_access_fail_closed() {
    assert!(!guarded_aliases(&[(Path::new("/work"), 999, true)], ROOT).is_empty());
    let info = overlay_info("lowerdir=/missing/layer");
    let reasons = guarded_aliases_with(&[], &info, |_| Err("missing".into()), |_| Ok(true));
    assert!(
        reasons.iter().any(|r| r.contains("cannot resolve overlay layer /missing/layer")),
        "{reasons:?}"
    );
    let info = format!("{ROOT}2 1 0:42 / /home rw - overlay overlay lowerdir=/tmp\n");
    let reasons = guarded_aliases(&[(Path::new("/home/u/.ssh"), 2, false)], &info);
    assert!(reasons.iter().any(|r| r.contains("lives on overlayfs")), "{reasons:?}");
}

#[test]
fn guarded_overlap_matrix() {
    for (tree, id, info, expected) in [
        (
            "/mnt/h",
            2,
            format!("{ROOT}2 1 8:1 /home/u /mnt/h rw - ext4 root rw\n"),
            "/mnt/h is also visible at /home/u",
        ),
        (
            "/home/u/work",
            1,
            format!("{ROOT}2 1 8:1 /home/u/work/cache /victim/.git/hooks rw - ext4 root rw\n"),
            "/home/u/work/cache is also visible at /victim/.git/hooks",
        ),
        (
            "/home/u/work",
            1,
            format!("{ROOT}2 1 8:1 /home/u/work /mnt/other rw - ext4 root rw\n"),
            "/home/u/work is also visible at /mnt/other",
        ),
        (
            "/home/u/work",
            1,
            format!("{ROOT}2 1 8:1 /home/u/work/a/b /mnt/x rw - ext4 root rw\n"),
            "/home/u/work/a/b is also visible at /mnt/x",
        ),
        (
            "/home/u/repo",
            1,
            "1 0 0:42 /@home /home rw - btrfs root rw\n2 0 0:42 / /mnt/top rw - btrfs root rw\n"
                .into(),
            "/home/u/repo is also visible at /mnt/top/@home/u/repo",
        ),
        (
            "/home/u/.ssh",
            1,
            format!("{ROOT}2 1 8:1 /home /mnt/home rw - ext4 root rw\n"),
            "/home/u/.ssh is also visible at /mnt/home/u/.ssh",
        ),
    ] {
        for writable in [false, true] {
            let reasons = guarded_aliases(&[(Path::new(tree), id, writable)], &info);
            assert!(reasons.contains(&expected.to_owned()), "{info}: {reasons:?}");
        }
    }
}

#[test]
fn writable_nonlocal_filesystems_are_refused() {
    for fs_type in ["overlay", "fuse.sshfs", "nfs4", "9p", "virtiofs", "autofs"] {
        for point in ["/", "/work", "/work/mnt"] {
            let info = format!("{ROOT}2 1 0:42 / {point} rw - {fs_type} source rw\n");
            let id = if point == "/work/mnt" { 1 } else { 2 };
            let reasons = guarded_aliases(&[(Path::new("/work"), id, true)], &info);
            assert!(
                reasons.iter().any(|r| r.contains("non-local") || r.contains("autofs")),
                "{info}: {reasons:?}"
            );
        }
    }
}

#[test]
fn overlay_layers_decode_data_only_and_escaped_paths() {
    assert_eq!(
        overlay_layers(
            r"lowerdir=/first\072colon::/second\040space:,upperdir=/upper\134slash,workdir=/work"
        )
        .unwrap(),
        ["/first:colon", "/second space", r"/upper\slash", "/work"].map(PathBuf::from)
    );
}
