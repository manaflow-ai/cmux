use std::collections::HashMap;

use super::*;
use crate::manifest::{Item, Kind, Manifest};
use crate::{Fetch, FetchError};

/// Serves bytes by entry from memory.
struct Bytes(HashMap<u32, Vec<u8>>);

impl Fetch for Bytes {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let bytes = self.0.get(&entry).ok_or(FetchError::Failed)?;
        let start = usize::try_from(offset).unwrap().min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Ok(bytes[start..end].to_vec())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries.iter().map(|entry| self.0.get(entry).cloned().ok_or(FetchError::Failed)).collect()
    }

    fn cache(&self) -> bool {
        false
    }
}

fn me() -> Who {
    // SAFETY: getuid and getgid have no preconditions.
    unsafe { Who { uid: libc::getuid(), gid: libc::getgid() } }
}

/// `README.md`, `src/{a.rs,b.rs}`, `src/deep/d.rs` and a link to the readme, served over NFS.
fn setup() -> (tempfile::TempDir, Nfs) {
    let files: [(&str, &[u8]); 4] = [
        ("README.md", b"readme"),
        ("src/a.rs", b"fn a() {}"),
        ("src/b.rs", b"fn b() {}"),
        ("src/deep/d.rs", b"fn d() {}"),
    ];
    let mut items: Vec<Item> = files
        .iter()
        .map(|(path, bytes)| Item {
            path: (*path).into(),
            kind: Kind::File,
            mode: 0o644,
            size: bytes.len() as u64,
            mtime_ns: 1_700_000_000_123_456_789,
            link: None,
        })
        .collect();
    items.push(Item {
        path: "link".into(),
        kind: Kind::Link,
        mode: 0o777,
        size: 9,
        mtime_ns: 1,
        link: Some("README.md".into()),
    });
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let bytes = files
        .iter()
        .map(|(path, bytes)| (manifest.resolve(path).unwrap(), bytes.to_vec()))
        .collect();
    let state = tempfile::tempdir().unwrap();
    let who = me();
    let overlay =
        Overlay::open(manifest, state.path(), Arc::new(Bytes(bytes)), (who.uid, who.gid)).unwrap();
    (state, Nfs::new(Arc::new(overlay), who))
}

fn name(text: &str) -> filename3 {
    nfsstring(text.as_bytes().to_vec())
}

async fn path_id(nfs: &Nfs, path: &str) -> fileid3 {
    let mut id = nfs.root_dir();
    for part in path.split('/') {
        id = nfs.lookup(id, &name(part)).await.unwrap();
    }
    id
}

async fn names(nfs: &Nfs, dir: fileid3) -> Vec<String> {
    let listed = nfs.readdir(dir, 0, usize::MAX).await.unwrap();
    assert!(listed.end);
    listed.entries.iter().map(|entry| String::from_utf8(entry.name.0.clone()).unwrap()).collect()
}

async fn read_all(nfs: &Nfs, id: fileid3) -> Vec<u8> {
    let (bytes, eof) = nfs.read(id, 0, 1 << 20).await.unwrap();
    assert!(eof);
    bytes
}

#[tokio::test]
async fn lookups_answer_dot_and_dot_dot() {
    let (_state, nfs) = setup();
    let root = nfs.root_dir();
    let src = path_id(&nfs, "src").await;
    let deep = path_id(&nfs, "src/deep").await;
    assert_eq!(nfs.lookup(deep, &name(".")).await.unwrap(), deep);
    assert_eq!(nfs.lookup(deep, &name("..")).await.unwrap(), src);
    assert_eq!(nfs.lookup(src, &name("..")).await.unwrap(), root);
    assert_eq!(nfs.lookup(root, &name("..")).await.unwrap(), root);
    assert!(matches!(nfs.lookup(root, &name("nope")).await, Err(nfsstat3::NFS3ERR_NOENT)));
}

#[tokio::test]
async fn attributes_carry_the_manifest() {
    let (_state, nfs) = setup();
    let a = nfs.getattr(path_id(&nfs, "src/a.rs").await).await.unwrap();
    assert!(matches!(a.ftype, ftype3::NF3REG));
    assert_eq!((a.size, a.mode, a.uid, a.fsid), (9, 0o644, me().uid, FSID));
    assert_eq!((a.mtime.seconds, a.mtime.nseconds), (1_700_000_000, 123_456_789));
    let src = nfs.getattr(path_id(&nfs, "src").await).await.unwrap();
    assert!(matches!(src.ftype, ftype3::NF3DIR));
    let link = path_id(&nfs, "link").await;
    assert!(matches!(nfs.getattr(link).await.unwrap().ftype, ftype3::NF3LNK));
    assert_eq!(nfs.readlink(link).await.unwrap().0, b"README.md");
}

#[tokio::test]
async fn listings_page_by_cookie() {
    let (_state, nfs) = setup();
    let root = nfs.root_dir();
    assert_eq!(names(&nfs, root).await, ["README.md", "link", "src"]);
    let first = nfs.readdir(root, 0, 2).await.unwrap();
    assert!(!first.end);
    assert_eq!(first.entries.len(), 2);
    let after = first.entries[1].fileid;
    let rest = nfs.readdir(root, after, 2).await.unwrap();
    assert!(rest.end);
    assert_eq!(rest.entries.iter().map(|entry| entry.name.0.clone()).collect::<Vec<_>>(), [b"src"]);
    assert_eq!(rest.entries[0].attr.fileid, rest.entries[0].fileid);
    let gone = nfs.readdir(root, 999_999, 2).await;
    assert!(matches!(gone, Err(nfsstat3::NFS3ERR_BAD_COOKIE)));
}

#[tokio::test]
async fn reads_say_where_the_file_ends() {
    let (_state, nfs) = setup();
    let readme = path_id(&nfs, "README.md").await;
    assert_eq!(nfs.read(readme, 0, 3).await.unwrap(), (b"rea".to_vec(), false));
    assert_eq!(nfs.read(readme, 3, 100).await.unwrap(), (b"dme".to_vec(), true));
    assert_eq!(nfs.read(readme, 50, 10).await.unwrap(), (Vec::new(), true));
}

#[tokio::test]
async fn writes_land_in_the_upper_folder() {
    let (state, nfs) = setup();
    let src = path_id(&nfs, "src").await;
    let attr = sattr3 { mode: set_mode3::mode(0o600), ..sattr3::default() };
    let (new, made) = nfs.create(src, &name("new.rs"), attr).await.unwrap();
    assert_eq!((made.mode, made.size), (0o600, 0));
    let written = nfs.write(new, 0, b"fn new() {}").await.unwrap();
    assert_eq!(written.size, 11);
    assert_eq!(read_all(&nfs, new).await, b"fn new() {}");
    assert_eq!(std::fs::read(state.path().join("upper/src/new.rs")).unwrap(), b"fn new() {}");

    // A lower file written: copied up, then changed.
    let a = path_id(&nfs, "src/a.rs").await;
    nfs.write(a, 3, b"A").await.unwrap();
    assert_eq!(read_all(&nfs, a).await, b"fn A() {}");

    let truncate = sattr3 { size: set_size3::size(2), ..sattr3::default() };
    assert_eq!(nfs.setattr(a, truncate).await.unwrap().size, 2);
    assert_eq!(read_all(&nfs, a).await, b"fn");

    let exclusive = nfs.create_exclusive(src, &name("lock")).await.unwrap();
    assert_eq!(nfs.getattr(exclusive).await.unwrap().size, 0);
    assert!(matches!(nfs.create_exclusive(src, &name("lock")).await, Err(nfsstat3::NFS3ERR_EXIST)));
}

#[tokio::test]
async fn folders_names_and_links_change() {
    let (_state, nfs) = setup();
    let root = nfs.root_dir();
    let (made, attr) = nfs.mkdir(root, &name("out")).await.unwrap();
    assert!(matches!(attr.ftype, ftype3::NF3DIR));
    assert_eq!(attr.mode, DIR_MODE);
    let (link, _) = nfs
        .symlink(made, &name("to-readme"), &nfsstring(b"../README.md".to_vec()), &sattr3::default())
        .await
        .unwrap();
    assert_eq!(nfs.readlink(link).await.unwrap().0, b"../README.md");

    let src = path_id(&nfs, "src").await;
    nfs.rename(src, &name("b.rs"), made, &name("b2.rs")).await.unwrap();
    assert_eq!(names(&nfs, src).await, ["a.rs", "deep"]);
    assert_eq!(names(&nfs, made).await, ["b2.rs", "to-readme"]);
    assert_eq!(read_all(&nfs, path_id(&nfs, "out/b2.rs").await).await, b"fn b() {}");

    // REMOVE takes a file; RMDIR arrives the same way and takes a folder.
    nfs.remove(src, &name("a.rs")).await.unwrap();
    assert!(matches!(nfs.remove(src, &name("deep")).await, Err(nfsstat3::NFS3ERR_NOTEMPTY)));
    let deep = path_id(&nfs, "src/deep").await;
    nfs.remove(deep, &name("d.rs")).await.unwrap();
    nfs.remove(src, &name("deep")).await.unwrap();
    assert!(names(&nfs, src).await.is_empty());
    assert!(matches!(nfs.lookup(src, &name("a.rs")).await, Err(nfsstat3::NFS3ERR_NOENT)));
}

#[test]
fn errnos_map_to_nfs_statuses() {
    assert!(matches!(status(libc::ENOENT), nfsstat3::NFS3ERR_NOENT));
    assert!(matches!(status(libc::ENOTEMPTY), nfsstat3::NFS3ERR_NOTEMPTY));
    assert!(matches!(status(libc::EXDEV), nfsstat3::NFS3ERR_XDEV));
    assert!(matches!(status(libc::ESTALE), nfsstat3::NFS3ERR_STALE));
    assert!(matches!(status(12345), nfsstat3::NFS3ERR_IO));
}

#[test]
fn times_round_trip() {
    let at = nfstime3 { seconds: 1_700_000_000, nseconds: 5 };
    assert_eq!(time_ns(at), 1_700_000_000_000_000_005);
    let back = time(time_ns(at));
    assert_eq!((back.seconds, back.nseconds), (at.seconds, at.nseconds));
    assert_eq!(time(-1).seconds, 0);
}

#[test]
fn mount_options_name_the_port() {
    let options = mount_options(4321);
    assert!(options.contains("port=4321,mountport=4321"));
    assert!(options.contains("vers=3") && options.contains("nobrowse"));
}
