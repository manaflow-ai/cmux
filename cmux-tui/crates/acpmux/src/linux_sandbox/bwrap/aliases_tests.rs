use super::*;

const ROOT: &str = "1 0 8:1 / / rw - ext4 root rw\n";

fn guarded_aliases(trees: &[(&Path, u64, bool)], info: &str) -> Vec<String> {
    guarded_aliases_with(trees, info, |p| Ok(p.to_path_buf()), |_| Ok(true))
}

fn overlay_info(options: &str) -> String {
    format!("{ROOT}2 1 0:42 / /mnt/leak rw - overlay overlay {options}\n")
}

/// A second mount of the home: /home/u is also mounted at /alias/u.
const SECOND_HOME: &str =
    "1 0 8:1 / / rw - ext4 root rw\n57 1 8:1 /home/u /alias/u rw - ext4 root rw\n";

/// systemd `PrivateTmp=yes` (a CI runner's unit): the private folder is bound over `/tmp`, so
/// the root mount's copy of it at `/tmp/systemd-private-*/tmp` is covered, not a second view.
#[test]
fn regression_private_tmp_is_no_alias_of_a_tree_under_tmp() {
    let private = "/tmp/systemd-private-39c3-runner.service-LCB624/tmp";
    let info = format!("{ROOT}30 1 8:1 {private} /tmp rw - ext4 root rw\n");
    let trees = [(Path::new("/tmp/fixture/spawn-tmp"), 30, true)];
    assert_eq!(guarded_aliases(&trees, &info), Vec::<String>::new());
    // Nor is the root mount's covered copy a second view of a HOME under /tmp to rebuild.
    assert!(home_views(Path::new("/tmp/fixture/home"), 30, &info).unwrap().is_empty());
    // The same folder bound somewhere uncovered is still a second view.
    let exposed = format!("{info}31 1 8:1 {private} /mnt/tmp-again rw - ext4 root rw\n");
    let reasons = guarded_aliases(&trees, &exposed);
    assert!(
        reasons.contains(
            &"/tmp/fixture/spawn-tmp is also visible at /mnt/tmp-again/fixture/spawn-tmp"
                .into()
        ),
        "{reasons:?}"
    );
    // A second mount of the whole root at /srv shows the private folder with nothing over it.
    let beside = format!("{info}32 1 8:1 / /srv rw - ext4 root rw\n");
    let reasons = guarded_aliases(&trees, &beside);
    assert!(
        reasons.iter().any(|r| r
            .starts_with("/tmp/fixture/spawn-tmp is also visible at /srv/tmp/systemd-private")),
        "{reasons:?}"
    );
}

#[test]
fn regression_home_alias_refuses_without_a_rebuilt_view() {
    let trees = [
        (Path::new("/home/u/.aws"), 1, false),
        (Path::new("/home/u/.ssh"), 1, false),
        (Path::new("/home/u/Projects/repo"), 1, true),
    ];
    let reasons = guarded_aliases(&trees, SECOND_HOME);
    for name in [".aws", ".ssh", "Projects/repo"] {
        let want = format!("/home/u/{name} is also visible at /alias/u/{name}");
        assert!(reasons.contains(&want), "{want}: {reasons:?}");
    }
}

#[test]
fn home_views_finds_every_whole_home_alias_and_nothing_else() {
    let views = |info: &str| home_views(Path::new("/home/u"), 1, info).unwrap();
    assert_eq!(views(SECOND_HOME), [(57, PathBuf::from("/alias/u"))]);
    assert!(views(ROOT).is_empty());
    // A second mount of / shows the HOME at its own subpath.
    let sysroot = format!("{ROOT}3 1 8:1 / /mnt/sysroot rw - ext4 root rw\n");
    assert_eq!(views(&sysroot), [(3, PathBuf::from("/mnt/sysroot/home/u"))]);
    // A separate /home partition bound again elsewhere.
    let part = "1 0 8:1 / / rw - ext4 root rw\n2 1 8:2 / /home rw - ext4 home rw\n3 1 8:2 /u /alias/u rw - ext4 home rw\n";
    assert_eq!(
        home_views(Path::new("/home/u"), 2, part).unwrap(),
        [(3, PathBuf::from("/alias/u"))]
    );
    // Not views: another device, a subtree of HOME, HOME at a point inside itself.
    let other_device = format!("{ROOT}3 1 8:9 /home/u /alias/u rw - ext4 root rw\n");
    assert!(views(&other_device).is_empty());
    let subtree = format!("{ROOT}3 1 8:1 /home/u/.ssh /mnt/ssh rw - ext4 root rw\n");
    assert!(views(&subtree).is_empty());
    let nested = format!("{ROOT}3 1 8:1 /home/u /home/u/loop rw - ext4 root rw\n");
    assert!(views(&nested).is_empty());
}

#[test]
fn home_views_refuses_a_hidden_or_nested_view() {
    let home = Path::new("/home/u");
    let hidden = format!("{SECOND_HOME}58 1 0:42 / /alias rw - tmpfs tmpfs rw\n");
    let error = home_views(home, 1, &hidden).unwrap_err();
    assert!(error.contains("hidden by another mount"), "{error}");
    let nested = format!("{SECOND_HOME}58 57 8:1 /home/u /alias/u/inner rw - ext4 root rw\n");
    let error = home_views(home, 1, &nested).unwrap_err();
    assert!(error.contains("lies inside another"), "{error}");
}

fn rebuilt() -> Vec<HomeView> {
    vec![(1, PathBuf::from("/home/u")), (57, PathBuf::from("/alias/u"))]
}

fn check_rebuilt(trees: &[(&Path, u64, bool)], info: &str) -> Vec<String> {
    guarded_aliases_viewed(trees, info, &rebuilt(), |p| Ok(p.to_path_buf()), |_| Ok(true))
}

#[test]
fn rebuilt_home_view_accepts_only_aliases_inside_it() {
    let trees = [
        (Path::new("/home/u/.aws"), 1, false),
        (Path::new("/home/u/.ssh"), 1, false),
        (Path::new("/home/u/.claude/projects/s/memory"), 1, false),
        (Path::new("/home/u/Projects/repo"), 1, true),
    ];
    let reasons = check_rebuilt(&trees, SECOND_HOME);
    assert!(reasons.is_empty(), "{reasons:?}");
    // A guarded path outside HOME is not covered by the rebuilt view.
    let sysroot = format!("{SECOND_HOME}3 1 8:1 /etc /mnt/etc rw - ext4 root rw\n");
    let reasons = check_rebuilt(&[(Path::new("/etc/shadow"), 1, false)], &sysroot);
    assert!(reasons.contains(&"/etc/shadow is also visible at /mnt/etc/shadow".into()));
    // A second alias the plan has no view for still refuses.
    let twice = format!("{SECOND_HOME}58 1 8:1 /home/u/.ssh /mnt/ssh rw - ext4 root rw\n");
    let reasons = check_rebuilt(&trees, &twice);
    assert!(
        reasons.contains(&"/home/u/.ssh is also visible at /mnt/ssh".into()),
        "{reasons:?}"
    );
    // A view computed for another mount does not vouch for this one.
    let reasons = guarded_aliases_viewed(
        &trees,
        SECOND_HOME,
        &[(1, PathBuf::from("/home/u")), (99, PathBuf::from("/alias/u"))],
        |p| Ok(p.to_path_buf()),
        |_| Ok(true),
    );
    assert!(!reasons.is_empty());
}

#[test]
fn masked_by_rebuild_matches_both_ends_by_their_own_mount() {
    let rebuilt = rebuilt();
    let (home, alias) = (Path::new("/home/u/.ssh"), Path::new("/alias/u/.ssh"));
    assert!(masked_by_rebuild(home, 1, alias, 57, &rebuilt));
    assert!(masked_by_rebuild(alias, 57, home, 1, &rebuilt));
    // The source reached through a mount that is not its view's.
    assert!(!masked_by_rebuild(home, 57, alias, 57, &rebuilt));
    assert!(!masked_by_rebuild(home, 99, alias, 57, &rebuilt));
    // The alternate reached through a mount that is not its view's.
    assert!(!masked_by_rebuild(home, 1, alias, 1, &rebuilt));
    // A view root itself, and the same view at both ends, never match.
    assert!(!masked_by_rebuild(Path::new("/home/u"), 1, Path::new("/alias/u"), 57, &rebuilt));
    assert!(!masked_by_rebuild(home, 1, home, 1, &rebuilt));
}

#[test]
fn a_writable_root_named_at_the_second_view_is_accepted_and_its_root_is_not() {
    let cwd = [(Path::new("/alias/u/Projects/repo"), 57, true)];
    let reasons = check_rebuilt(&cwd, SECOND_HOME);
    assert!(reasons.is_empty(), "{reasons:?}");
    // The view root itself is the whole HOME: never accepted.
    let root = [(Path::new("/alias/u"), 57, true)];
    let reasons = check_rebuilt(&root, SECOND_HOME);
    assert!(reasons.contains(&"/alias/u is also visible at /home/u".into()), "{reasons:?}");
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
        let reasons = guarded_aliases_with(
            &[],
            &overlay_info(option),
            |p| Ok(p.to_path_buf()),
            |_| Ok(true),
        );
        assert!(reasons.iter().any(|r| r.contains("unknown overlay")), "{reasons:?}");
    }
}

#[test]
fn reachable_overlay_non_layer_options_are_accepted() {
    let info =
        overlay_info("lowerdir=/var/lib/x,redirect_dir=on,index=on,metacopy=on,xino=auto");
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
        ("/mnt/h", 2, format!("{ROOT}2 1 8:1 /home/u /mnt/h rw - ext4 root rw\n"), "/mnt/h is also visible at /home/u"),
        ("/home/u/work", 1, format!("{ROOT}2 1 8:1 /home/u/work/cache /victim/.git/hooks rw - ext4 root rw\n"), "/home/u/work/cache is also visible at /victim/.git/hooks"),
        ("/home/u/work", 1, format!("{ROOT}2 1 8:1 /home/u/work /mnt/other rw - ext4 root rw\n"), "/home/u/work is also visible at /mnt/other"),
        ("/home/u/work", 1, format!("{ROOT}2 1 8:1 /home/u/work/a/b /mnt/x rw - ext4 root rw\n"), "/home/u/work/a/b is also visible at /mnt/x"),
        ("/home/u/repo", 1, "1 0 0:42 /@home /home rw - btrfs root rw\n2 0 0:42 / /mnt/top rw - btrfs root rw\n".into(), "/home/u/repo is also visible at /mnt/top/@home/u/repo"),
        ("/home/u/.ssh", 1, format!("{ROOT}2 1 8:1 /home /mnt/home rw - ext4 root rw\n"), "/home/u/.ssh is also visible at /mnt/home/u/.ssh"),
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
    assert_eq!(overlay_layers(r"lowerdir=/first\072colon::/second\040space:,upperdir=/upper\134slash,workdir=/work").unwrap(),
        ["/first:colon", "/second space", r"/upper\slash", "/work"].map(PathBuf::from));
}
