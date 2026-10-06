//! The file store (section 2): two append-only streams of JSON lines, one
//! file per local day, every line fsynced before the write returns.
//!
//! Memory: the store keeps where each line is, never its text. A location is
//! 16 bytes, so a million messages index in 16 MB and their tree (about two
//! nodes per message) in 32 MB, against gigabytes for cached texts. Reads are
//! positioned reads of one line; the view (~500 lines) renders in a few ms.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, FileExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use optchat_core::{Kind, NodeId, Store};

use crate::lines::{self, MainHead, MainIn, TreeIn};
use crate::report::Report;

/// Creates `dir` (and its parents) and makes it 0700: the log holds
/// everything the user ever pasted, secrets included, and other accounts on a
/// shared Mac must not read it. An existing directory is tightened too.
pub fn private_dir(dir: &Path) -> io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

/// Mode of every day file (see `private_dir`).
const FILE_MODE: u32 = 0o600;

/// Where one line is: file index in its stream, byte offset, length without
/// the newline. `len == 0` marks an absent node (a JSON line is never empty).
#[derive(Clone, Copy, Debug, Default)]
struct Loc {
    file: u32,
    len: u32,
    offset: u64,
}

impl Loc {
    fn is_some(self) -> bool {
        self.len != 0
    }
}

/// One stream directory (`main/` or `tree/`) and its current day file.
struct Stream {
    dir: PathBuf,
    /// Day file names, in load order; a `Loc::file` indexes this.
    files: Vec<String>,
    /// The file being appended to: (index, handle, its length).
    writer: Option<(u32, File, u64)>,
}

impl Stream {
    fn open(dir: PathBuf) -> io::Result<Stream> {
        private_dir(&dir)?;
        let mut files: Vec<String> = fs::read_dir(&dir)?
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n.ends_with(".jsonl"))
            .collect();
        files.sort();
        // Day files written before files were private are tightened at load.
        for name in &files {
            fs::set_permissions(dir.join(name), fs::Permissions::from_mode(FILE_MODE))?;
        }
        Ok(Stream {
            dir,
            files,
            writer: None,
        })
    }

    fn path(&self, file: u32) -> PathBuf {
        self.dir.join(&self.files[file as usize])
    }

    /// Appends one line (newline included) with one write, then fsyncs it, to
    /// today's file. Returns where it went.
    fn append(&mut self, line: &str) -> io::Result<Loc> {
        let name = format!("{}.jsonl", lines::today());
        if self
            .writer
            .as_ref()
            .is_none_or(|(k, _, _)| self.files[*k as usize] != name)
        {
            let path = self.dir.join(&name);
            let created = !path.exists();
            let file = OpenOptions::new()
                .create(true)
                .append(true)
                .mode(FILE_MODE)
                .open(&path)?;
            if created {
                // The new file's directory entry must survive a crash too.
                File::open(&self.dir)?.sync_all()?;
            }
            let len = file.metadata()?.len();
            let k = match self.files.iter().position(|n| *n == name) {
                Some(k) => k,
                None => {
                    self.files.push(name);
                    self.files.len() - 1
                }
            };
            self.writer = Some((k as u32, file, len));
        }
        let (k, file, len) = self.writer.as_mut().expect("writer opened above");
        file.write_all(line.as_bytes())?;
        // On Apple platforms std's sync_all is F_FULLFSYNC, which reaches the disk.
        file.sync_all()?;
        let loc = Loc {
            file: *k,
            len: (line.len() - 1) as u32,
            offset: *len,
        };
        *len += line.len() as u64;
        Ok(loc)
    }
}

/// Positioned reads need an open file; a day file is opened once and kept,
/// up to a few dozen (years of day files would exceed the fd limit).
#[derive(Default)]
struct Readers {
    open: HashMap<(bool, u32), File>,
}

const READERS: usize = 32;

/// The chat directory's two streams and their index.
pub struct FileStore {
    main: Stream,
    tree: Stream,
    messages: Vec<Loc>,
    /// Per level, indexed by `i`.
    nodes: Vec<Vec<Loc>>,
    node_count: usize,
    readers: RefCell<Readers>,
}

/// Lines of one file with their byte offsets, after making sure it ends in a newline.
fn file_lines(path: &Path, reports: &mut Vec<Report>) -> io::Result<Vec<(usize, u64, Vec<u8>)>> {
    let mut bytes = fs::read(path)?;
    if !bytes.is_empty() && bytes.last() != Some(&b'\n') {
        let mut f = OpenOptions::new().append(true).open(path)?;
        f.write_all(b"\n")?;
        f.sync_all()?;
        bytes.push(b'\n');
        reports.push(Report::MissingNewline {
            file: path.to_path_buf(),
        });
    }
    let mut out = Vec::new();
    let mut offset = 0u64;
    for (n, line) in bytes.split(|b| *b == b'\n').enumerate() {
        let len = line.len() as u64;
        if !line.is_empty() {
            out.push((n + 1, offset, line.to_vec()));
        }
        offset += len + 1;
    }
    Ok(out)
}

impl FileStore {
    /// Loads `dir/main` and `dir/tree`, creating them if needed. Invalid
    /// lines are reported and skipped. Returns the built nodes with their
    /// text sizes, for `Memory::load`. Fails if message ids are not exactly
    /// 0..T: the log would be ambiguous, and appending would reuse an id.
    pub fn open(
        dir: &Path,
        reports: &mut Vec<Report>,
    ) -> io::Result<(FileStore, Vec<(NodeId, usize)>)> {
        let main = Stream::open(dir.join("main"))?;
        let tree = Stream::open(dir.join("tree"))?;

        let mut found: Vec<(u64, Loc)> = Vec::new();
        for k in 0..main.files.len() as u32 {
            let path = main.path(k);
            for (n, offset, line) in file_lines(&path, reports)? {
                let head = serde_json::from_slice::<MainHead>(&line)
                    .map_err(|e| e.to_string())
                    .and_then(|h| match Kind::parse(&h.kind) {
                        Some(_) => Ok(h),
                        None => Err(format!("unknown kind {:?}", h.kind)),
                    });
                match head {
                    Ok(h) => found.push((
                        h.i,
                        Loc {
                            file: k,
                            len: line.len() as u32,
                            offset,
                        },
                    )),
                    Err(error) => reports.push(Report::InvalidLine {
                        file: path.clone(),
                        line: n,
                        error,
                    }),
                }
            }
        }
        // Ids are global and files split by local day; a clock moved back can
        // put a later id in an earlier file, so order by id, not by file.
        found.sort_by_key(|(i, _)| *i);
        for (k, (i, _)) in found.iter().enumerate() {
            if *i != k as u64 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("message ids are not contiguous: expected {k}, found {i}"),
                ));
            }
        }
        let messages: Vec<Loc> = found.into_iter().map(|(_, l)| l).collect();
        let t = messages.len() as u64;

        let mut nodes: Vec<Vec<Loc>> = Vec::new();
        let mut built = Vec::new();
        for k in 0..tree.files.len() as u32 {
            let path = tree.path(k);
            for (n, offset, line) in file_lines(&path, reports)? {
                let node = match serde_json::from_slice::<TreeIn>(&line) {
                    Ok(t) if t.l < 64 => t,
                    Ok(_) => {
                        let error = "level out of range".to_string();
                        reports.push(Report::InvalidLine {
                            file: path.clone(),
                            line: n,
                            error,
                        });
                        continue;
                    }
                    Err(e) => {
                        reports.push(Report::InvalidLine {
                            file: path.clone(),
                            line: n,
                            error: e.to_string(),
                        });
                        continue;
                    }
                };
                let id = NodeId::new(node.l, node.i);
                let ignore = |why| Report::IgnoredNode {
                    file: path.clone(),
                    line: n,
                    node: id,
                    why,
                };
                let end = node
                    .i
                    .checked_add(1)
                    .and_then(|e| e.checked_mul(1u64 << node.l));
                if end.is_none_or(|end| end > t) {
                    reports.push(ignore("past the end of the log"));
                    continue;
                }
                let level = node.l as usize;
                if nodes.len() <= level {
                    nodes.resize_with(level + 1, Vec::new);
                }
                let row = &mut nodes[level];
                let i = node.i as usize;
                if row.len() <= i {
                    row.resize(i + 1, Loc::default());
                }
                if row[i].is_some() {
                    reports.push(ignore("already loaded"));
                    continue;
                }
                row[i] = Loc {
                    file: k,
                    len: line.len() as u32,
                    offset,
                };
                built.push((id, node.text.len()));
            }
        }
        let store = FileStore {
            main,
            tree,
            messages,
            node_count: built.len(),
            nodes,
            readers: RefCell::default(),
        };
        Ok((store, built))
    }

    /// Number of messages, T.
    pub fn len(&self) -> u64 {
        self.messages.len() as u64
    }

    /// Number of stored nodes.
    pub fn node_count(&self) -> usize {
        self.node_count
    }

    /// Logs one message (fsynced) and returns its id. `date` is its ISO
    /// time (an imported message keeps its own); None: now.
    pub fn append_message(&mut self, kind: Kind, text: &str, date: Option<&str>) -> io::Result<u64> {
        let i = self.len();
        let now;
        let date = match date {
            Some(date) => date,
            None => {
                now = lines::now_iso();
                &now
            }
        };
        let loc = self.main.append(&lines::main_line(i, kind, text, date))?;
        self.messages.push(loc);
        Ok(i)
    }

    /// Stores one built node (fsynced).
    pub fn append_node(&mut self, node: NodeId, text: &str) -> io::Result<()> {
        let loc = self.tree.append(&lines::tree_line(node, text))?;
        let level = node.l as usize;
        if self.nodes.len() <= level {
            self.nodes.resize_with(level + 1, Vec::new);
        }
        let row = &mut self.nodes[level];
        if row.len() <= node.i as usize {
            row.resize(node.i as usize + 1, Loc::default());
        }
        row[node.i as usize] = loc;
        self.node_count += 1;
        Ok(())
    }

    /// The stored ISO date of message `i`.
    pub fn date(&self, i: u64) -> Option<String> {
        let loc = *self.messages.get(i as usize)?;
        Some(self.read_main(i, loc).date)
    }

    fn read(&self, main: bool, loc: Loc) -> io::Result<Vec<u8>> {
        let mut readers = self.readers.borrow_mut();
        if !readers.open.contains_key(&(main, loc.file)) {
            if readers.open.len() >= READERS {
                readers.open.clear();
            }
            let stream = if main { &self.main } else { &self.tree };
            readers
                .open
                .insert((main, loc.file), File::open(stream.path(loc.file))?);
        }
        let mut buf = vec![0u8; loc.len as usize];
        readers.open[&(main, loc.file)].read_exact_at(&mut buf, loc.offset)?;
        Ok(buf)
    }

    // The core's Store contract is infallible. A line that was fsynced and
    // indexed but cannot be read back means the disk is failing; going on
    // would write summaries of garbage into the permanent tree, so stop loudly.
    fn read_main(&self, i: u64, loc: Loc) -> MainIn {
        let bytes = self
            .read(true, loc)
            .unwrap_or_else(|e| panic!("optchat: cannot read message {i}: {e}"));
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|e| panic!("optchat: message {i} changed on disk: {e}"))
    }
}

impl Store for FileStore {
    fn message(&self, i: u64) -> (Kind, String) {
        let loc = self.messages[i as usize];
        let m = self.read_main(i, loc);
        let kind =
            Kind::parse(&m.kind).unwrap_or_else(|| panic!("optchat: message {i} changed on disk"));
        (kind, m.text)
    }

    fn node(&self, id: NodeId) -> Option<String> {
        let loc = *self.nodes.get(id.l as usize)?.get(id.i as usize)?;
        if !loc.is_some() {
            return None;
        }
        let bytes = self
            .read(false, loc)
            .unwrap_or_else(|e| panic!("optchat: cannot read node {}: {e}", id.name()));
        let node: TreeIn = serde_json::from_slice(&bytes)
            .unwrap_or_else(|e| panic!("optchat: node {} changed on disk: {e}", id.name()));
        Some(node.text)
    }
}
