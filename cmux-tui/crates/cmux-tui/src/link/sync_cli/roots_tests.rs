use super::super::Pushed;
use super::*;

fn sha(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}

fn manifest(files: &[(&str, String)]) -> Manifest {
    Manifest {
        version: 1,
        files: files
            .iter()
            .map(|(path, sha256)| {
                (
                    (*path).to_owned(),
                    Pushed { sha256: sha256.clone(), permissions: 0o644, revision: "r".into() },
                )
            })
            .collect(),
        ..Manifest::default()
    }
}

fn snapshot(paths: &[(&str, Held)]) -> Snapshot {
    Snapshot {
        version: 1,
        seq: 1,
        at: 0,
        action: "push".into(),
        restored: None,
        paths: paths.iter().map(|(path, held)| ((*path).to_owned(), held.clone())).collect(),
        git: None,
        touched: BTreeSet::new(),
        moved_git: false,
    }
}

#[test]
fn a_tree_is_its_header_then_one_sorted_sha_per_line() {
    let blobs: BTreeSet<String> = [sha(2), sha(1)].into_iter().collect();
    let tree = String::from_utf8(tree(&blobs)).unwrap();
    assert_eq!(tree, format!("cmux-sync-tree 1\n{}\n{}\n", sha(1), sha(2)));
    assert_eq!(String::from_utf8(super::tree(&BTreeSet::new())).unwrap(), "cmux-sync-tree 1\n");
}

#[test]
fn the_tree_names_the_record_and_the_kept_history_and_a_cut_files_pieces() {
    // `big` is cut into pieces 10 and 11; `old` is only in history; an empty hash (a file a
    // failed fetch left, recorded with none) and a symlink name nothing.
    let next = manifest(&[("a.rs", sha(1)), ("big.bin", sha(2)), ("stray", String::new())]);
    let history = [snapshot(&[
        ("a.rs", Held::File { sha256: sha(3), permissions: 0o644 }),
        ("link", Held::Link { text: "a.rs".into() }),
    ])];
    let files = files_named(&next, &history);
    assert_eq!(files, [sha(1), sha(2), sha(3)].into_iter().collect());
    let sent: Chunks = [(sha(2), vec![sha(10), sha(11)])].into_iter().collect();
    // A file no longer named drops out of the kept pieces.
    let kept: Chunks = [(sha(9), vec![sha(12)])].into_iter().collect();
    let chunks = chunks_kept(kept, &sent, &files);
    assert_eq!(chunks, sent);
    let blobs = blobs_needed(&files, &chunks);
    assert_eq!(blobs, [sha(1), sha(3), sha(10), sha(11)].into_iter().collect());
}

#[test]
fn pieces_recorded_by_an_earlier_push_stay_named_while_the_file_is() {
    let next = manifest(&[("big.bin", sha(2))]);
    let files = files_named(&next, &[]);
    let kept: Chunks = [(sha(2), vec![sha(10)])].into_iter().collect();
    let chunks = chunks_kept(kept.clone(), &Chunks::new(), &files);
    assert_eq!(chunks, kept);
    assert_eq!(blobs_needed(&files, &chunks), [sha(10)].into_iter().collect());
}

#[test]
fn a_pair_id_is_stable_opaque_and_one_per_folder_pair() {
    let local = Path::new("/Users/someone/src/app");
    let id = pair(local, "/home/cmux/work/app");
    assert_eq!(id, pair(local, "/home/cmux/work/app"));
    assert_ne!(id, pair(local, "/home/cmux/work/other"));
    assert_ne!(id, pair(Path::new("/Users/someone/src/other"), "/home/cmux/work/app"));
    // The store's pair: 1 to 128 of A-Z a-z 0-9 . _ -, never a path.
    assert!((1..=128).contains(&id.len()));
    assert!(id.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)), "{id}");
    assert!(!id.contains("someone"));
    assert_eq!(id, base::key(local, "/home/cmux/work/app"));
}
