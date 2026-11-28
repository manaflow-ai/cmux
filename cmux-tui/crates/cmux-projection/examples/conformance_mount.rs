//! The conformance harness's mount (RFD 0007, "Conformance"): projects a local folder, as the Mac
//! would, through the real wire ([`cmux_projection::link`]) and mounts it the way the machine does,
//! so file system suites (pjdfstest, fsx, xfstests) run against the same code the agent sees.
//!
//!     conformance_mount SOURCE MOUNT STATE [--lower|--ro] [--allow-other] [--fsname=NAME] [--disk-atime]
//!
//! SOURCE is the stand-in Mac folder (files, folders and links, every one shared). MOUNT is an
//! empty folder. STATE holds the upper layer and the cache. `--lower` mounts the read-only lower
//! alone (every write answers `EROFS`). It prints `mounted` once the mount answers and stays until
//! SIGINT/SIGTERM, then unmounts.

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux::main()
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("projected folders mount on Linux only");
    std::process::exit(2);
}

#[cfg(target_os = "linux")]
mod linux {
    use std::os::unix::fs::{FileExt as _, MetadataExt as _};
    use std::os::unix::net::UnixStream;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;

    use cmux_projection::link::{Link, Source, answer_asks};
    use cmux_projection::manifest::{Item, Kind, Manifest};
    use cmux_projection::mount::Options;
    use cmux_projection::overlay::Overlay;
    use cmux_projection::wire::{self, Part};

    struct Served {
        path: PathBuf,
        size: u64,
        mtime_ns: i64,
    }

    /// The stand-in Mac: serves each file's bytes, refusing a file changed since the manifest.
    struct Folder(Vec<Option<Served>>);

    impl Source for Folder {
        fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
            let Some(Some(served)) = self.0.get(entry as usize) else {
                return Part::status(wire::REFUSED);
            };
            let Ok(file) = std::fs::File::open(&served.path) else {
                return Part::status(wire::FAILED);
            };
            let Ok(meta) = file.metadata() else { return Part::status(wire::FAILED) };
            if meta.len() != served.size || mtime_ns(&meta) != served.mtime_ns {
                return Part::status(wire::CHANGED);
            }
            let want = u64::from(len).min(served.size.saturating_sub(offset));
            let mut bytes = vec![0u8; usize::try_from(want).unwrap_or(0)];
            match file.read_exact_at(&mut bytes, offset) {
                Ok(()) => Part::ok(bytes),
                Err(_) => Part::status(wire::FAILED),
            }
        }

        fn whole(&self, entry: u32) -> Part {
            let size =
                self.0.get(entry as usize).and_then(Option::as_ref).map_or(0, |served| served.size);
            match u32::try_from(size) {
                Ok(len) if len <= wire::MAX_READ => self.read(entry, 0, len),
                _ => Part::status(wire::FAILED),
            }
        }
    }

    fn mtime_ns(meta: &std::fs::Metadata) -> i64 {
        meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec())
    }

    fn walk(root: &Path, at: &Path, items: &mut Vec<Item>, paths: &mut Vec<(String, PathBuf)>) {
        let Ok(read) = std::fs::read_dir(at) else { return };
        for entry in read.flatten() {
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
            let Ok(relative) = path.strip_prefix(root) else { continue };
            let Some(relative) = relative.to_str().map(str::to_owned) else { continue };
            let kind = if meta.is_dir() {
                Kind::Dir
            } else if meta.file_type().is_symlink() {
                Kind::Link
            } else if meta.is_file() {
                Kind::File
            } else {
                continue;
            };
            let link = (kind == Kind::Link).then(|| {
                std::fs::read_link(&path)
                    .map(|target| target.display().to_string())
                    .unwrap_or_default()
            });
            items.push(Item {
                path: relative.clone(),
                kind,
                mode: meta.mode() & 0o7777,
                size: meta.len(),
                mtime_ns: mtime_ns(&meta),
                link,
            });
            match kind {
                Kind::Dir => walk(root, &path, items, paths),
                Kind::File => paths.push((relative, path)),
                Kind::Link => {}
            }
        }
    }

    pub fn main() -> anyhow::Result<()> {
        // Blocked before any thread starts: every thread inherits the mask, so only sigwait sees them.
        let signals = block_signals();
        let args: Vec<String> = std::env::args().skip(1).collect();
        let lower_only = args.iter().any(|arg| arg == "--lower" || arg == "--ro");
        let disk_atime = args.iter().any(|arg| arg == "--disk-atime");
        let allow_other = args.iter().any(|arg| arg == "--allow-other");
        let places: Vec<&String> = args.iter().filter(|arg| !arg.starts_with("--")).collect();
        let [source, at, state] = places.as_slice() else {
            anyhow::bail!(
                "usage: conformance_mount SOURCE MOUNT STATE [--lower|--ro] [--allow-other] [--fsname=NAME] [--disk-atime]"
            );
        };
        let source = std::fs::canonicalize(source)?;
        let (mut items, mut paths) = (Vec::new(), Vec::new());
        walk(&source, &source, &mut items, &mut paths);
        let root_meta = std::fs::metadata(&source)?;
        let manifest = Manifest::build(mtime_ns(&root_meta), items)?;
        let mut served: Vec<Option<Served>> = Vec::new();
        served.resize_with(manifest.len(), || None);
        for (relative, path) in paths {
            let Ok(meta) = std::fs::metadata(&path) else { continue };
            if let Some(slot) =
                manifest.resolve(&relative).and_then(|index| served.get_mut(index as usize))
            {
                *slot = Some(Served { path, size: meta.len(), mtime_ns: mtime_ns(&meta) });
            }
        }
        let (machine_end, mac_end) = UnixStream::pair()?;
        let folder = Folder(served);
        std::thread::spawn(move || {
            let reader = mac_end.try_clone().expect("clone the Mac's end");
            let _ = answer_asks(reader, mac_end, &folder);
        });
        let link = Arc::new(Link::default());
        let serving = link.clone();
        std::thread::spawn(move || {
            let reader = machine_end.try_clone().expect("clone the machine's end");
            serving.serve(reader, machine_end);
        });
        let owner = (unsafe_uid(), unsafe_gid());
        let overlay = Arc::new(Overlay::open(Arc::new(manifest), Path::new(state), link, owner)?);
        let at = std::fs::canonicalize(at)?;
        let fsname = args.iter().find_map(|arg| arg.strip_prefix("--fsname=")).map(str::to_owned);
        let options =
            Options { read_only: lower_only, allow_other, fsname, disk_atime, idle_exit: None };
        let mounted = cmux_projection::mount::mount_with(overlay, &at, options)?;
        std::fs::metadata(&at)?;
        println!("mounted");
        wait_for(&signals, &at);
        mounted.unmount();
        Ok(())
    }

    fn unsafe_uid() -> u32 {
        // SAFETY: getuid has no preconditions and cannot fail.
        unsafe { libc::getuid() }
    }

    fn unsafe_gid() -> u32 {
        // SAFETY: getgid has no preconditions and cannot fail.
        unsafe { libc::getgid() }
    }

    fn block_signals() -> libc::sigset_t {
        // SAFETY: a zeroed sigset is a valid argument to sigemptyset; the mask only blocks.
        unsafe {
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigaddset(&mut set, libc::SIGINT);
            libc::sigaddset(&mut set, libc::SIGTERM);
            libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
            set
        }
    }

    /// Waits for SIGINT/SIGTERM, or for the mount at `at` to go (an `umount` from outside, as
    /// xfstests does between tests).
    fn wait_for(set: &libc::sigset_t, at: &Path) {
        let at = at.display().to_string();
        let mounted = || {
            std::fs::read_to_string("/proc/self/mountinfo").is_ok_and(|info| {
                info.lines().any(|line| line.split(' ').nth(4) == Some(at.as_str()))
            })
        };
        let second = libc::timespec { tv_sec: 1, tv_nsec: 0 };
        loop {
            // SAFETY: `set` was filled by block_signals and is blocked on every thread.
            let got = unsafe { libc::sigtimedwait(set, std::ptr::null_mut(), &second) };
            if got > 0 || !mounted() {
                return;
            }
        }
    }
}
