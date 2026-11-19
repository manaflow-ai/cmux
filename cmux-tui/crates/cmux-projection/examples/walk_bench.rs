//! The Mac-side walk of a projected folder, timed (RFD 0007 fix #2).
//!
//!     walk_bench make DIR N            a tree of N empty files (50 a folder, 4 levels)
//!     walk_bench new DIR [THREADS]     `walk::walk` (fstatat only, THREADS threads)
//!     walk_bench old DIR               the shape `cmux link project serve` had before: one
//!                                      thread, an fstatat, an open and an fstat a file, then a
//!                                      second stat pass by path
//!
//! Each walk prints one JSON line: entries, files, the walk's ms and the encoded manifest's bytes
//! (the manifest built from what the walk found, as the serve sends it).

#[cfg(unix)]
fn main() -> anyhow::Result<()> {
    unix::main()
}

#[cfg(not(unix))]
fn main() {}

#[cfg(unix)]
mod unix {
    use std::os::unix::fs::MetadataExt as _;
    use std::path::{Path, PathBuf};
    use std::time::Instant;

    use cmux_projection::manifest::{Item, Kind, Manifest};
    use cmux_projection::walk::{self, Found, Rules};

    /// No rule: every entry goes (the bench times the disk, not the rules).
    struct All;

    impl Rules for All {
        type Skip = ();
        fn folder(&self, _: &str, _: &Path, _: &str) -> Option<()> {
            None
        }
        fn entry(&self, _: &str) -> Option<()> {
            None
        }
    }

    pub fn main() -> anyhow::Result<()> {
        let args: Vec<String> = std::env::args().skip(1).collect();
        let arg = |at: usize| args.get(at).cloned().unwrap_or_default();
        match arg(0).as_str() {
            "make" => make(Path::new(&arg(1)), arg(2).parse()?),
            "new" => {
                let threads = arg(2).parse().unwrap_or(walk::DEFAULT_THREADS);
                let started = Instant::now();
                let found = walk::walk(Path::new(&arg(1)), &All, threads)?;
                let walk_ms = started.elapsed().as_millis();
                let items = found
                    .into_iter()
                    .filter_map(|(path, found)| match found {
                        Found::File(stat) => {
                            Some(item(path, Kind::File, stat.size, stat.mtime_ns, None))
                        }
                        Found::Link { text: Some(text), stat } => {
                            Some(item(path, Kind::Link, 0, stat.mtime_ns, Some(text)))
                        }
                        _ => None,
                    })
                    .collect();
                report("new", threads, walk_ms, items)
            }
            "old" => {
                let started = Instant::now();
                let mut listed = Vec::new();
                old_walk(Path::new(&arg(1)), "", &mut listed)?;
                // The second pass: a stat of every file by its path.
                let items = listed
                    .into_iter()
                    .filter_map(|(relative, path)| {
                        let meta = std::fs::symlink_metadata(&path).ok()?;
                        let mtime = meta.mtime() * 1_000_000_000 + meta.mtime_nsec();
                        Some(item(relative, Kind::File, meta.len(), mtime, None))
                    })
                    .collect();
                report("old", 1, started.elapsed().as_millis(), items)
            }
            _ => anyhow::bail!("usage: walk_bench make DIR N | new DIR [THREADS] | old DIR"),
        }
    }

    fn item(path: String, kind: Kind, size: u64, mtime_ns: i64, link: Option<String>) -> Item {
        Item { path, kind, mode: 0o644, size, mtime_ns, link }
    }

    fn report(how: &str, threads: usize, walk_ms: u128, items: Vec<Item>) -> anyhow::Result<()> {
        let files = items.iter().filter(|item| item.kind == Kind::File).count();
        let manifest = Manifest::build(0, items)?;
        let bytes = manifest.encode()?.len();
        println!(
            "{{\"how\":\"{how}\",\"threads\":{threads},\"entries\":{},\"files\":{files},\
             \"walk_ms\":{walk_ms},\"manifest_bytes\":{bytes}}}",
            manifest.len()
        );
        Ok(())
    }

    /// The walk as it was: names, then per name an `lstat`, and per file an open and an `fstat`
    /// (the identity the copy takes from a descriptor).
    fn old_walk(dir: &Path, prefix: &str, out: &mut Vec<(String, PathBuf)>) -> anyhow::Result<()> {
        // A name gone meanwhile (a live tree) is passed over, as the walk does.
        let gone = |error: &std::io::Error| error.kind() == std::io::ErrorKind::NotFound;
        let entries = match std::fs::read_dir(dir) {
            Err(error) if gone(&error) => return Ok(()),
            other => other?,
        };
        for entry in entries {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let relative =
                if prefix.is_empty() { name.clone() } else { format!("{prefix}/{name}") };
            let path = dir.join(&name);
            let meta = match std::fs::symlink_metadata(&path) {
                Err(error) if gone(&error) => continue,
                other => other?,
            };
            if meta.is_dir() {
                old_walk(&path, &relative, out)?;
            } else if meta.is_file() {
                match std::fs::File::open(&path).and_then(|opened| opened.metadata()) {
                    Err(error) if gone(&error) => continue,
                    other => drop(other?),
                }
                out.push((relative, path));
            }
        }
        Ok(())
    }

    fn make(top: &Path, files: usize) -> anyhow::Result<()> {
        for index in 0..files {
            let dir = top.join(format!(
                "p{}/m{}/s{}",
                index / 100_000,
                (index / 2_000) % 50,
                (index / 50) % 40
            ));
            if index % 50 == 0 {
                std::fs::create_dir_all(&dir)?;
            }
            std::fs::File::create(dir.join(format!("f{}.txt", index % 50)))?;
        }
        Ok(())
    }
}
