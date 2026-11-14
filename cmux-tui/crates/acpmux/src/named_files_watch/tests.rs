use super::*;
use std::sync::mpsc;
use std::time::Duration;

fn watch(files: Vec<PathBuf>) -> (NamedFilesWatch, mpsc::Receiver<Vec<PathBuf>>) {
    let (tx, rx) = mpsc::channel();
    let watch = NamedFilesWatch::start(files, move |changed| tx.send(changed.to_vec()).is_err())
        .expect("the files are watched");
    (watch, rx)
}

fn arrives(rx: &mpsc::Receiver<Vec<PathBuf>>, file: &Path, what: &str) {
    let changed = rx.recv_timeout(Duration::from_secs(5)).unwrap_or_else(|_| {
        panic!("{what}: no event");
    });
    assert!(changed.iter().any(|c| c == file), "{what}: {changed:?}");
    while rx.recv_timeout(Duration::from_millis(200)).is_ok() {}
}

fn quiet(rx: &mpsc::Receiver<Vec<PathBuf>>, what: &str) {
    let noise = rx.recv_timeout(Duration::from_millis(500));
    assert!(noise.is_err(), "{what} sent an event: {noise:?}");
}

/// The folder of the file is `$HOME`, where every agent writes its logs and transcripts:
/// writes below it send nothing; the file created, saved by rename and written in place each
/// arrives.
#[test]
fn writes_to_other_files_send_nothing_and_a_file_saved_by_rename_is_still_seen() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let file = home.join(".zshrc");
    let deep = home.join(".codex/sessions/2026/11/12");
    std::fs::create_dir_all(&deep).unwrap();
    let (watch, rx) = watch(vec![file.clone()]);
    for n in 0..20 {
        std::fs::write(deep.join("rollout.jsonl"), format!("{n}\n")).unwrap();
        std::fs::write(home.join(".codex/logs_2.sqlite-wal"), format!("{n}\n")).unwrap();
    }
    quiet(&rx, "a write to another file");
    std::fs::write(&file, "export A=1\n").unwrap();
    arrives(&rx, &file, "created");
    let saved = home.join(".zshrc.tmp");
    std::fs::write(&saved, "export A=2\n").unwrap();
    std::fs::rename(&saved, &file).unwrap();
    arrives(&rx, &file, "saved by rename");
    std::fs::write(&file, "export A=3\n").unwrap();
    arrives(&rx, &file, "written in place after the rename");
    let other = home.join(".claude.json.tmp");
    std::fs::write(&other, "{}").unwrap();
    std::fs::rename(&other, home.join(".claude.json")).unwrap();
    quiet(&rx, "a rename of another file");
    drop(watch);
}

/// A file whose folders do not exist yet (`~/.config/cmux/cmux-next.json` on a new Mac): the
/// folders made and the file written in one burst still arrive, and a write after that too.
#[test]
fn a_file_in_folders_made_later_is_seen() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let file = home.join(".config/cmux/cmux-next.json");
    let (watch, rx) = watch(vec![file.clone()]);
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    std::fs::write(home.join(".codex/history.jsonl"), "x").unwrap();
    quiet(&rx, "a write in another folder");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, "{}").unwrap();
    arrives(&rx, &file, "made with its folders");
    std::fs::write(&file, "{\"a\": 1}").unwrap();
    arrives(&rx, &file, "written again");
    drop(watch);
}

/// A symlinked folder (a dotfiles checkout): a save by rename in the link's target folder
/// arrives under the name as given.
#[test]
fn a_file_under_a_symlinked_folder_is_seen_in_its_real_folder() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let dotfiles = root.join("dotfiles/config");
    std::fs::create_dir_all(dotfiles.join("cmux")).unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::os::unix::fs::symlink(&dotfiles, home.join(".config")).unwrap();
    let file = home.join(".config/cmux/cmux-next.json");
    let (watch, rx) = watch(vec![file.clone()]);
    let saved = dotfiles.join("cmux/.cmux-next.json.tmp");
    std::fs::write(&saved, "{}").unwrap();
    std::fs::rename(&saved, dotfiles.join("cmux/cmux-next.json")).unwrap();
    arrives(&rx, &file, "saved by rename in the real folder");
    drop(watch);
}
