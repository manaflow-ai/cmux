//! Builds the indexed manifest from paths given in any order.

use std::collections::{HashMap, VecDeque};

use super::{Entry, Index, Kind, Manifest, ManifestError, Stat, split_path};

/// Collects `(relative path, stat)` pairs in any order and produces the indexed [`Manifest`].
///
/// The Mac's walker and its skip rules live with the caller; this type only checks that the
/// paths make a clean tree: relative, no empty, `.` or `..` components, no NUL, no duplicates,
/// and every parent present as a directory.
#[derive(Debug)]
pub struct Builder {
    root: String,
    root_stat: Stat,
    items: HashMap<String, Stat>,
    skipped: u64,
}

impl Builder {
    /// Starts a manifest for a folder. The label is informational (for example the Mac path).
    pub fn new(root_label: &str) -> Builder {
        Builder {
            root: root_label.to_owned(),
            root_stat: Stat::dir(0o755, 0, 0),
            items: HashMap::new(),
            skipped: 0,
        }
    }

    /// Sets the root directory's own stat (by default mode 755 and zero times).
    pub fn root_stat(&mut self, stat: Stat) -> Result<(), ManifestError> {
        if stat.kind != Kind::Dir {
            return Err(ManifestError::BadStat {
                path: String::new(),
                reason: "the root must be a directory".into(),
            });
        }
        self.root_stat = stat;
        Ok(())
    }

    /// Adds one path below the root.
    pub fn add(&mut self, path: &str, stat: Stat) -> Result<(), ManifestError> {
        let parts = split_path(path)?;
        if parts.is_empty() {
            return Err(ManifestError::BadPath {
                path: path.to_owned(),
                reason: "use root_stat for the root",
            });
        }
        stat.check().map_err(|reason| ManifestError::BadStat { path: path.to_owned(), reason })?;
        if self.items.contains_key(path) {
            return Err(ManifestError::Duplicate(path.to_owned()));
        }
        if self.items.len() >= (u32::MAX - 1) as usize {
            return Err(ManifestError::BadPath {
                path: path.to_owned(),
                reason: "too many entries",
            });
        }
        self.items.insert(path.to_owned(), stat);
        Ok(())
    }

    /// Counts paths the caller's skip rules left out.
    pub fn add_skipped(&mut self, n: u64) {
        self.skipped += n;
    }

    /// Produces the manifest: breadth first, each directory's children contiguous and sorted.
    pub fn build(self) -> Result<Manifest, ManifestError> {
        let mut by_parent: HashMap<&str, Vec<(&str, &str)>> = HashMap::new();
        for (path, stat) in &self.items {
            let (parent, name) = path.rsplit_once('/').unwrap_or(("", path.as_str()));
            if !parent.is_empty() && self.items.get(parent).is_none_or(|s| s.kind != Kind::Dir) {
                return Err(ManifestError::MissingParent(path.clone()));
            }
            debug_assert!(stat.check().is_ok());
            by_parent.entry(parent).or_default().push((name, path.as_str()));
        }
        let mut entries = Vec::with_capacity(self.items.len() + 1);
        entries.push(Entry::new(String::new(), 0, self.root_stat.clone()));
        let mut queue: VecDeque<(Index, &str)> = VecDeque::from([(0, "")]);
        while let Some((idx, dir)) = queue.pop_front() {
            let Some(mut kids) = by_parent.remove(dir) else {
                continue;
            };
            kids.sort_unstable_by(|a, b| a.0.cmp(b.0));
            entries[idx as usize].first_child = entries.len() as Index;
            entries[idx as usize].n_children = kids.len() as u32;
            for (name, path) in kids {
                let child = entries.len() as Index;
                let stat = self.items[path].clone();
                if stat.kind == Kind::Dir {
                    queue.push_back((child, path));
                }
                entries.push(Entry::new(name.to_owned(), idx, stat));
            }
        }
        Ok(Manifest { root: self.root, entries, skipped: self.skipped })
    }
}
