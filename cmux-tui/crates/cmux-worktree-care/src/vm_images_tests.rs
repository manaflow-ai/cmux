use super::*;
use crate::caches::{Options, Report, run};
use crate::never_delete::NeverDelete;
use crate::policy::Pressure;
use crate::procs::{Open, Process, Uses};
use crate::store::Store;
use crate::store::care_tests::scratch;

fn no_uses() -> Result<Vec<Process>, String> {
    Ok(Vec::new())
}

fn not_open(_: &Path) -> Result<Option<u32>, String> {
    Ok(None)
}

/// Sets every time in `path`'s tree `days` back.
fn age(path: &Path, days: u64) {
    let when = std::time::SystemTime::now() - Duration::from_secs(days * 86_400);
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let child = entry.path();
            if std::fs::symlink_metadata(&child).unwrap().file_type().is_symlink() {
                continue;
            }
            if child.is_dir() {
                stack.push(child.clone());
            }
            std::fs::File::open(&child).unwrap().set_modified(when).unwrap();
        }
    }
    std::fs::File::open(path).unwrap().set_modified(when).unwrap();
}

/// A fake `tart`: `list` prints `list.json`, `delete NAME` logs the name and
/// removes the path `map` gives it.
#[cfg(unix)]
fn fake_tart(home: &Path, list: &str, map: &[(&str, &Path)]) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = home.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("list.json"), list).unwrap();
    let lines: String = map.iter().map(|(n, p)| format!("{n}\t{}\n", p.display())).collect();
    std::fs::write(bin.join("map"), lines).unwrap();
    let script = bin.join("tart");
    std::fs::write(
        &script,
        r#"#!/bin/sh
dir="$(dirname "$0")"
case "$1" in
  list) cat "$dir/list.json" ;;
  delete)
    echo "$2" >> "$dir/deleted"
    p=$(awk -F '\t' -v n="$2" '$1 == n { print $2 }' "$dir/map")
    if [ -L "$p" ]; then rm -f "$p"; elif [ -n "$p" ]; then rm -rf "$p"; fi ;;
  *) exit 2 ;;
esac
"#,
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

fn options<'a>(
    home: &'a Path,
    families: Vec<Family>,
    uses: &'a Uses,
    open: &'a Open,
    never: &'a NeverDelete,
    store: Option<&'a Store>,
) -> Options<'a> {
    Options {
        families,
        pressure: Pressure::Normal,
        now_ms: crate::inventory::now_ms(),
        apply: true,
        uses,
        open,
        measure: true,
        home,
        never,
        store,
        off: &[],
    }
}

fn item<'a>(report: &'a Report, path: &Path) -> &'a crate::caches::Item {
    report.items.iter().find(|i| i.path == path).unwrap_or_else(|| panic!("{report:?}"))
}

/// An OCI image Tart pulled: its digest folder and a tag link to it.
#[cfg(unix)]
fn image(root: &Path, repo: &str, tag: &str, digest: &str) -> (PathBuf, PathBuf) {
    let folder = root.join(repo).join(format!("sha256:{digest}"));
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("disk.img"), vec![1u8; 64 * 1024]).unwrap();
    std::fs::write(folder.join("config.json"), b"{}").unwrap();
    let link = root.join(repo).join(tag);
    std::os::unix::fs::symlink(format!("sha256:{digest}"), &link).unwrap();
    (folder, link)
}

#[cfg(unix)]
#[test]
fn an_unused_old_image_is_removed_and_a_running_one_kept() {
    let home = scratch("vm-oci");
    let root = home.join(".tart/cache/OCIs");
    let (old, old_tag) = image(&root, "ghcr.io/acme/macos", "sonoma", "aaa");
    let (busy, busy_tag) = image(&root, "ghcr.io/acme/runner", "latest", "bbb");
    age(&home.join(".tart"), 60);
    let list = r#"[
      {"Source":"OCI","Name":"ghcr.io/acme/macos:sonoma","State":"stopped","Running":false},
      {"Source":"OCI","Name":"ghcr.io/acme/macos@sha256:aaa","State":"stopped","Running":false},
      {"Source":"OCI","Name":"ghcr.io/acme/runner:latest","State":"running","Running":true},
      {"Source":"OCI","Name":"ghcr.io/acme/runner@sha256:bbb","State":"stopped","Running":false}
    ]"#;
    let tart = fake_tart(
        &home,
        list,
        &[
            ("ghcr.io/acme/macos:sonoma", &old_tag),
            ("ghcr.io/acme/macos@sha256:aaa", &old),
            ("ghcr.io/acme/runner:latest", &busy_tag),
            ("ghcr.io/acme/runner@sha256:bbb", &busy),
        ],
    );
    let family = family("tart-images", root, Vm::Tart, Shape::OciImages, tart, 30);
    let report =
        run(&options(&home, vec![family], &no_uses, &not_open, &crate::never_delete::NONE, None));
    assert!(!old.exists() && std::fs::symlink_metadata(&old_tag).is_err(), "{report:?}");
    assert!(busy.exists());
    let outcome = item(&report, &old).outcome.clone().unwrap();
    assert!(outcome.ok && outcome.freed > 64 * 1024 && outcome.archive.is_none());
    assert!(item(&report, &busy).verdict.reason.contains("is running"));
    let deleted = std::fs::read_to_string(home.join("bin/deleted")).unwrap();
    assert_eq!(deleted, "ghcr.io/acme/macos:sonoma\nghcr.io/acme/macos@sha256:aaa\n");
    let _ = std::fs::remove_dir_all(&home);
}

#[cfg(unix)]
#[test]
fn a_stopped_old_vm_is_archived_first_and_a_running_or_protected_one_kept() {
    let home = scratch("vm-local");
    let store = Store::open(home.join("store")).unwrap();
    let root = home.join(".tart/vms");
    let vm = |name: &str| {
        let path = root.join(name);
        std::fs::create_dir_all(&path).unwrap();
        std::fs::write(path.join("disk.img"), vec![2u8; 32 * 1024]).unwrap();
        std::fs::write(path.join("config.json"), b"{}").unwrap();
        path
    };
    let (stopped, running, kept) = (vm("old-runner"), vm("busy"), vm("golden"));
    age(&root, 60);
    let list = r#"[
      {"Source":"local","Name":"old-runner","State":"stopped"},
      {"Source":"local","Name":"busy","State":"running"},
      {"Source":"local","Name":"golden","State":"stopped"}
    ]"#;
    let tart =
        fake_tart(&home, list, &[("old-runner", &stopped), ("busy", &running), ("golden", &kept)]);
    let family = family("tart-vms", root.clone(), Vm::Tart, Shape::Machines, tart, 30);
    let never = NeverDelete::from_globs(["~/.tart/vms/golden".to_string()]);
    let report =
        run(&options(&home, vec![family.clone()], &no_uses, &not_open, &never, Some(&store)));
    assert!(!stopped.exists(), "{report:?}");
    assert!(running.exists() && kept.exists());
    let archive = item(&report, &stopped).outcome.clone().unwrap().archive.unwrap();
    assert!(archive.starts_with("vms/tart-vms/") && archive.ends_with("-old-runner.tar.gz"));
    assert!(store.dir.join(&archive).is_file());
    assert!(item(&report, &kept).verdict.reason.starts_with("never-delete"));

    // Without a store (no archive possible) or without its program, nothing goes.
    let report = run(&options(&home, vec![family], &no_uses, &not_open, &never, None));
    assert!(running.exists() && kept.exists());
    let missing = family_without_program(&root);
    let report2 = run(&options(&home, vec![missing], &no_uses, &not_open, &never, Some(&store)));
    assert!(running.exists());
    assert_eq!(item(&report2, &running).verdict.action, Action::Keep);
    let _ = report;
    let _ = std::fs::remove_dir_all(&home);
}

fn family_without_program(root: &Path) -> Family {
    family(
        "tart-vms",
        root.to_path_buf(),
        Vm::Tart,
        Shape::Machines,
        PathBuf::from("/nonexistent/tart"),
        30,
    )
}

#[test]
fn list_output_parses_tart_and_lume() {
    let tart = r#"[{"Source":"OCI","Name":"a:b","State":"stopped","Running":false},
                   {"Source":"local","Name":"vm","Running":true}]"#;
    let parsed = parse_list(tart).unwrap();
    assert_eq!(parsed[0], Listed { name: "a:b".into(), oci: true, running: false });
    assert!(parsed[1].running && !parsed[1].oci);
    let lume = r#"[{"name":"m","status":"running"},{"name":"n","status":"stopped"}]"#;
    let parsed = parse_list(lume).unwrap();
    assert!(parsed[0].running && !parsed[1].running);
    assert!(parse_list("not json").is_err());
}

#[test]
fn oci_names_map_to_tarts_cache_folders() {
    let root = Path::new("/c");
    assert_eq!(oci_path(root, "ghcr.io/a/b:tag"), Path::new("/c/ghcr.io/a/b/tag"));
    assert_eq!(oci_path(root, "ghcr.io/a/b@sha256:x"), Path::new("/c/ghcr.io/a/b/sha256:x"));
    assert_eq!(oci_path(root, "host:5000/a"), Path::new("/c/host:5000/a/latest"));
}
