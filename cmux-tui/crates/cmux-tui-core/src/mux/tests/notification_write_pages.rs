//! The WAL pages that ONE notification write puts on the disk, by b-tree.
//!
//! COUNT form (no clock): the registry is a file in a temporary directory.
//! The row reads the WAL file before and after one notification write. Each
//! frame after the WAL's header is a header of 24 bytes and one page: the
//! frame's first 4 bytes are the page's number, the next 4 are not zero in
//! the last frame of a commit, and bytes 8 to 16 are the salts of the WAL's
//! header (a frame with other salts is of an older WAL). `dbstat` gives the
//! b-tree of each page.
//!
//! The journal's subject rows have 2 b-trees: the table's own, in the order
//! `(sequence, kind, id)`, and an index in the order `(kind, id, sequence)`.
//! A write puts its subject rows at the end of the first one, and at one
//! place of the second one for each subject. The row asserts that a
//! notification write pays for no page of an index by subject.

use std::collections::BTreeMap;

use super::*;

const WAL_HEADER: usize = 32;
const WAL_FRAME_HEADER: usize = 24;
/// The start of the name of an index of the journal's subject rows by subject.
const BY_SUBJECT: &str = "journal_subject_index_by_subject";

fn database(mux: &Mux) -> &Path {
    mux.journal_kernel.database_path().expect("an on-disk registry")
}

/// The frames that the registry's WAL file holds now.
#[derive(Default)]
struct Wal {
    /// The 2 salts of the WAL's header. They change when the WAL starts
    /// again from its first frame.
    salts: Vec<u8>,
    /// Each frame of this WAL: its page number, and if it ends a commit.
    frames: Vec<(u32, bool)>,
}

fn read_wal(mux: &Mux) -> Wal {
    let mut path = database(mux).as_os_str().to_owned();
    path.push("-wal");
    let bytes = std::fs::read(&path).unwrap_or_default();
    let Some(header) = bytes.get(..WAL_HEADER) else { return Wal::default() };
    let page = u32::from_be_bytes(header[8..12].try_into().unwrap()) as usize;
    if page == 0 {
        return Wal::default();
    }
    let salts = header[16..24].to_vec();
    let mut frames = Vec::new();
    for frame in bytes[WAL_HEADER..].chunks_exact(WAL_FRAME_HEADER + page) {
        if frame[8..16] != salts[..] {
            break;
        }
        let number = u32::from_be_bytes(frame[..4].try_into().unwrap());
        frames.push((number, frame[4..8] != [0; 4]));
    }
    Wal { salts, frames }
}

/// The b-tree of each page of the registry, by `dbstat`.
fn page_trees(mux: &Mux) -> BTreeMap<u32, String> {
    let reader =
        crate::workspace_registry::open_registry_database_read_only(database(mux)).unwrap();
    let mut statement = reader.prepare("SELECT pageno, name FROM dbstat").unwrap();
    let pages = statement
        .query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)))
        .unwrap()
        .map(|row| {
            let (page, name) = row.unwrap();
            (u32::try_from(page).unwrap(), name)
        })
        .collect::<BTreeMap<_, _>>();
    pages
}

#[test]
fn one_notification_write_puts_no_page_of_an_index_by_subject_in_the_wal() {
    let root = std::env::temp_dir().join(format!(
        "cmux-notification-write-pages-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux("notification-write-pages", &root);
    // The maintenance worker checkpoints and seals on its own clock; the
    // count must see only what the write causes.
    mux.stop_journal_maintenance();
    // The counted write is not the first of its kind in the session.
    for index in 0..8 {
        mux.post_notification(
            format!("before {index}"),
            String::new(),
            NotificationLevel::Info,
            None,
        )
        .unwrap();
    }
    let before = read_wal(&mux);
    mux.post_notification("counted".into(), String::new(), NotificationLevel::Info, None).unwrap();
    let after = read_wal(&mux);
    let trees = page_trees(&mux);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    // A WAL that started again holds only the frames since that start.
    let same_wal = after.salts == before.salts && after.frames.len() >= before.frames.len();
    let frames = if same_wal { &after.frames[before.frames.len()..] } else { &after.frames[..] };
    assert!(
        !frames.is_empty(),
        "setup: the notification write put no frame in the WAL before its call returned"
    );
    let commits = frames.iter().filter(|(_, ends_a_commit)| *ends_a_commit).count();
    let mut by_tree = BTreeMap::<&str, usize>::new();
    for (page, _) in frames {
        let tree = trees.get(page).map_or("(no b-tree now: a free page)", String::as_str);
        *by_tree.entry(tree).or_default() += 1;
    }
    let by_subject = by_tree
        .iter()
        .filter(|(tree, _)| tree.starts_with(BY_SUBJECT))
        .map(|(_, frames)| *frames)
        .sum::<usize>();
    assert_eq!(
        by_subject,
        0,
        "one notification write (of no terminal) put {} WAL frames on the disk in {commits} \
         commits before its call returned (the WAL started again in the count: {}), and \
         {by_subject} of them are pages of an index of the journal's subject rows by subject. \
         Frames by b-tree: {by_tree:#?}",
        frames.len(),
        !same_wal,
    );
}
