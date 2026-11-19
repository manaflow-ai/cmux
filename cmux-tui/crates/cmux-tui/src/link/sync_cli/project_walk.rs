//! A projected folder outside git, listed by the copy's own rules ([`super::super::local`]'s
//! plain walk: no heavy folder, no secret or credential, symlinks only when they stay inside)
//! with [`cmux_projection::walk`]: every entry is looked at once with `fstatat` through the folder
//! holding it, never opened, on a few threads. The one stat gives the file's size, time and
//! identity (the device and inode its later reads must still find), so no second pass looks at
//! it again (RFD 0007, fix #2 of "Leo's real ~/Projects": that walk took 417-670 s of a 669-820 s
//! start).

use std::path::Path;

use cmux_projection::manifest::{Item, Kind};
use cmux_projection::walk::{self, Found, Rules};

use super::super::links;
use super::super::local::{LocalFile, Source, holdable, permissions_of};
use super::super::skips;
use super::Served;

/// The copy's rules for a folder outside git ([`Rules::Copy`](super::super::local::Rules)).
struct CopyRules<'a> {
    top: &'a Path,
}

impl Rules for CopyRules<'_> {
    type Skip = ();

    fn folder(&self, relative: &str, parent: &Path, name: &str) -> Option<()> {
        (skips::credential(relative, true).is_some() || skips::heavy(parent, name)).then_some(())
    }

    fn entry(&self, relative: &str) -> Option<()> {
        (relative == ".DS_Store"
            || skips::secret_at(self.top, relative)
                .or_else(|| skips::credential(relative, false))
                .is_some())
        .then_some(())
    }
}

/// The threads the walk uses: [`walk::DEFAULT_THREADS`], fewer on a smaller Mac.
fn threads() -> usize {
    std::thread::available_parallelism()
        .map_or(walk::DEFAULT_THREADS, std::num::NonZero::get)
        .min(walk::DEFAULT_THREADS)
}

/// The files (with what each is read from) and the symlinks of the folder `top` (canonical,
/// outside git), as the copy would list them.
pub(super) fn plain(top: &Path) -> anyhow::Result<(Vec<(String, Served)>, Vec<Item>)> {
    let found = walk::walk(top, &CopyRules { top }, threads())?;
    let mut files = Vec::with_capacity(found.len());
    let mut kept = Vec::new();
    for (relative, found) in found {
        // A name the machine cannot hold is left out, as the copy leaves it out.
        if !holdable(&relative) {
            continue;
        }
        match found {
            Found::File(stat) => {
                let file = LocalFile {
                    source: Source::File(top.join(&relative)),
                    permissions: permissions_of(stat.mode),
                    id: Some((stat.dev, stat.ino)),
                };
                files.push((relative, Served { file, size: stat.size, mtime_ns: stat.mtime_ns }));
            }
            Found::Link { text: Some(text), stat } => {
                let path = top.join(&relative);
                if let links::Local::Keep(linked) = links::local_with(top, &relative, &path, &text)
                    .map_err(|error| anyhow::anyhow!("cannot read {}: {error}", path.display()))?
                {
                    kept.push(Item {
                        path: relative,
                        kind: Kind::Link,
                        mode: 0o777,
                        size: 0,
                        mtime_ns: stat.mtime_ns,
                        link: Some(linked.target),
                    });
                }
            }
            Found::Link { text: None, .. }
            | Found::Special
            | Found::NotUtf8
            | Found::Skipped(()) => {}
        }
    }
    Ok((files, kept))
}
