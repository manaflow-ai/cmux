//! `cmux-projection`: a projected checkout of a git commit on a lane VM.
//!
//! ```text
//! cmux-projection git-mount --git-dir MIRROR --commit REV --at PATH [--keep DIR] [--fresh]
//!                           [--name NAME] [--ready-file FILE]
//! cmux-projection git-lower --git-dir MIRROR --commit REV --at PATH --index FILE [--sparse FILE]
//!                           [--keep DIR] [--ready-file FILE] [--allow-other]
//! cmux-projection git-unmount --at PATH
//! cmux-projection seed --git-dir MIRROR --listen ADDR [--rate BYTES_PER_S] [--conns N]
//! ```
//!
//! `git-lower` mounts commit REV's tree read only at PATH (every write answers EROFS) for many
//! checkouts to share as the lower layer of their own overlays, and writes its git index to FILE:
//! stat data as the mount serves it, so `git status` over the lower finds every file clean
//! without reading (fetching) it. No `.git`, no worktree, no build output links: each checkout on
//! top keeps its own. `--sparse FILE` (cone-mode folders, or git's pattern file for them) leaves
//! the rest out of the tree and the index. Blobs come as `git-mount`'s do, on first read.
//! `--allow-other` lets other users in, root among them: a kernel overlay mounted with `sudo`
//! reads its lower as root (it needs `user_allow_other` in `/etc/fuse.conf`).
//!
//! `git-mount` mounts commit REV of the bare repo MIRROR at PATH and serves it until PATH is
//! unmounted (`git-unmount`, or `fusermount3 -u PATH`). What it writes lands in an upper folder
//! under `--keep` (default `~/.cache/cmux-projection/<hash of PATH>`), which also holds the mtime
//! book and the build output folders (`target/` and the like), so mount the same PATH again and
//! cargo finds its last build fresh. `--fresh` starts a new checkout: the upper folder and the
//! worktree's index are made anew. git sees PATH as a worktree of MIRROR named NAME (default
//! `projected-<hash of PATH>`). Once the mount is up it prints one JSON line of timings on stderr
//! and writes it to `--ready-file`.
//!
//! The blobs MIRROR lacks are first asked of the fleet's seeds, the controller SSD and R2 that the
//! environment names, each answer checked against its id (`cmux_projection::peers`, hq RFD 0008),
//! and only the rest come from GitHub; `CMUX_PROJECTION_PEERS=0` sends them all to GitHub. `seed` serves MIRROR's blobs read only on ADDR
//! (a tailnet or VPC address, never 0.0.0.0) for the other hosts' chains.

#[cfg(target_os = "linux")]
fn main() -> std::process::ExitCode {
    match linux::run(std::env::args().skip(1).collect()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-projection: {error:#}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() -> std::process::ExitCode {
    eprintln!("cmux-projection: mounts are Linux only");
    std::process::ExitCode::from(2)
}

#[cfg(target_os = "linux")]
mod linux {
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::{Instant, SystemTime, UNIX_EPOCH};

    use cmux_projection::git::{self, Book, GitBlobs, Layout, Projection, Worktree};
    use cmux_projection::mount;
    use cmux_projection::overlay::Overlay;
    use cmux_projection::peers::{self, Chain, SeedLimits};

    const USAGE: &str = "usage: cmux-projection git-mount --git-dir MIRROR --commit REV --at PATH \
                         [--keep DIR] [--fresh] [--name NAME] [--ready-file FILE]\n       \
                         cmux-projection git-lower --git-dir MIRROR --commit REV --at PATH \
                         --index FILE [--sparse FILE] [--keep DIR] [--ready-file FILE] [--allow-other]\n       \
                         cmux-projection git-unmount --at PATH\n       \
                         cmux-projection seed --git-dir MIRROR --listen ADDR [--rate BYTES_PER_S] \
                         [--conns N]";

    #[derive(Default)]
    struct Args {
        git_dir: Option<PathBuf>,
        commit: Option<String>,
        at: Option<PathBuf>,
        keep: Option<PathBuf>,
        name: Option<String>,
        ready_file: Option<PathBuf>,
        index: Option<PathBuf>,
        sparse: Option<PathBuf>,
        listen: Option<String>,
        rate: Option<u64>,
        conns: Option<usize>,
        fresh: bool,
        allow_other: bool,
    }

    fn parse(args: &[String]) -> anyhow::Result<Args> {
        let mut parsed = Args::default();
        let mut at = 0;
        while at < args.len() {
            let Some(flag) = args.get(at).map(String::as_str) else { break };
            if flag == "--fresh" || flag == "--allow-other" {
                if flag == "--fresh" {
                    parsed.fresh = true;
                } else {
                    parsed.allow_other = true;
                }
                at += 1;
                continue;
            }
            let value =
                args.get(at + 1).ok_or_else(|| anyhow::anyhow!("{flag} needs a value\n{USAGE}"))?;
            match flag {
                "--git-dir" => parsed.git_dir = Some(value.into()),
                "--commit" => parsed.commit = Some(value.clone()),
                "--at" => parsed.at = Some(value.into()),
                "--keep" => parsed.keep = Some(value.into()),
                "--name" => parsed.name = Some(value.clone()),
                "--ready-file" => parsed.ready_file = Some(value.into()),
                "--index" => parsed.index = Some(value.into()),
                "--sparse" => parsed.sparse = Some(value.into()),
                "--listen" => parsed.listen = Some(value.clone()),
                "--rate" => parsed.rate = Some(value.parse()?),
                "--conns" => parsed.conns = Some(value.parse()?),
                _ => anyhow::bail!("unknown flag {flag}\n{USAGE}"),
            }
            at += 2;
        }
        Ok(parsed)
    }

    pub fn run(args: Vec<String>) -> anyhow::Result<()> {
        let (command, rest) = args.split_first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
        let args = parse(rest)?;
        if command == "seed" {
            return seed(&args);
        }
        let at = args.at.clone().ok_or_else(|| anyhow::anyhow!("--at is required\n{USAGE}"))?;
        match command.as_str() {
            "git-mount" => git_mount(&args, &at),
            "git-lower" => git_lower(&args, &at),
            "git-unmount" => {
                let status =
                    std::process::Command::new("fusermount3").arg("-u").arg(&at).status()?;
                anyhow::ensure!(status.success(), "fusermount3 -u {} failed", at.display());
                Ok(())
            }
            _ => anyhow::bail!(USAGE),
        }
    }

    fn seed(args: &Args) -> anyhow::Result<()> {
        let git_dir = args
            .git_dir
            .clone()
            .ok_or_else(|| anyhow::anyhow!("--git-dir is required\n{USAGE}"))?;
        let listen =
            args.listen.clone().ok_or_else(|| anyhow::anyhow!("--listen is required\n{USAGE}"))?;
        let addr: std::net::SocketAddr = listen
            .parse()
            .map_err(|_| anyhow::anyhow!("--listen takes IP:PORT, got {listen}\n{USAGE}"))?;
        anyhow::ensure!(
            !addr.ip().is_unspecified(),
            "--listen takes the tailnet or VPC address, never every interface (0.0.0.0, 0, [::])"
        );
        let mut limits = SeedLimits::default();
        if let Some(rate) = args.rate {
            limits.rate = rate;
        }
        if let Some(conns) = args.conns {
            limits.conns = conns;
        }
        peers::serve(&git_dir.canonicalize()?, &listen, limits)
    }

    /// FNV-1a: a short stable name for a mount path.
    fn hash(text: &str) -> String {
        let hash = text.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
        });
        format!("{:08x}", hash >> 32)
    }

    fn ms(since: Instant) -> u128 {
        since.elapsed().as_millis()
    }

    /// Fetches the blobs of `commit` that `git_dir` lacks (peers, the controller SSD, R2, then
    /// GitHub) and answers how many there were.
    fn fill_missing(git_dir: &Path, commit: &str) -> anyhow::Result<usize> {
        let missing = git::missing(git_dir, commit)?;
        // Nothing missing (every mount after the first of a commit): no chain, so no peer index
        // is read over the network before the mount comes up.
        let chain = if missing.is_empty() { None } else { Chain::from_env() };
        let rest = match chain {
            Some(chain) => {
                let (rest, filled) =
                    chain.fill(&missing, &|oid, bytes| peers::write_loose(git_dir, oid, bytes));
                eprintln!(
                    "cmux-projection: {} missing blobs: {} from peers, {} from the controller SSD, \
                     {} from R2, {} rejected answers, {} sources dropped, {} left for git",
                    missing.len(),
                    filled.peer,
                    filled.ssd,
                    filled.r2,
                    filled.rejected,
                    filled.dropped,
                    rest.len()
                );
                rest
            }
            None => missing.clone(),
        };
        git::fetch_missing(git_dir, &rest)?;
        Ok(missing.len())
    }

    /// The cone-mode sparse-checkout folders in `text` (`git sparse-checkout set` folders one a
    /// line, or the pattern file git writes for them: only its positive folder lines count).
    fn sparse_folders(text: &str) -> Vec<String> {
        text.lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with(['#', '!']) && !line.contains('*'))
            .map(|line| line.trim_matches('/').to_owned())
            .filter(|line| !line.is_empty())
            .collect()
    }

    /// Whether cone mode checks `path` out for `folders`: every file at the top, every file in a
    /// folder above one of `folders`, everything inside one.
    fn in_cone(path: &str, folders: &[String]) -> bool {
        let parent = path.rsplit_once('/').map_or("", |(parent, _)| parent);
        parent.is_empty()
            || folders.iter().any(|folder| {
                path.strip_prefix(folder.as_str()).is_some_and(|rest| rest.starts_with('/'))
                    || folder.strip_prefix(parent).is_some_and(|rest| rest.starts_with('/'))
            })
    }

    #[cfg(test)]
    #[test]
    fn cone_mode_keeps_the_top_the_folders_above_and_everything_inside() {
        let folders = sparse_folders("/*\n!/*/\n/cmux-tui/\n!/cmux-tui/*/\n/cmux-tui/crates/x/\n");
        assert_eq!(folders, ["cmux-tui", "cmux-tui/crates/x"]);
        let folders = sparse_folders("cmux-tui/crates/x\n");
        for (path, kept) in [
            ("README.md", true),
            ("cmux-tui/Cargo.toml", true),
            ("cmux-tui/crates/Cargo.toml", true),
            ("cmux-tui/crates/x/src/lib.rs", true),
            ("cmux-tui/crates/y/src/lib.rs", false),
            ("cmux-tui/crates/xy/lib.rs", false),
            ("web/index.ts", false),
        ] {
            assert_eq!(in_cone(path, &folders), kept, "{path}");
        }
    }

    /// `git-lower`: commit REV's tree, read only, at PATH, and its index at FILE.
    fn git_lower(args: &Args, at: &Path) -> anyhow::Result<()> {
        let started = Instant::now();
        let git_dir =
            args.git_dir.clone().ok_or_else(|| anyhow::anyhow!("--git-dir is required"))?;
        let git_dir = git_dir.canonicalize()?;
        let rev = args.commit.clone().ok_or_else(|| anyhow::anyhow!("--commit is required"))?;
        let index_file =
            args.index.clone().ok_or_else(|| anyhow::anyhow!("--index is required\n{USAGE}"))?;
        if std::fs::metadata(at).is_err_and(|error| error.raw_os_error() == Some(libc::ENOTCONN)) {
            mount::unmount_stale(at);
        }
        std::fs::create_dir_all(at)?;
        let at = at.canonicalize()?;
        let keep = match &args.keep {
            Some(keep) => keep.clone(),
            None => {
                let home = std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("no HOME"))?;
                PathBuf::from(home).join(".cache/cmux-projection").join(hash(&at.to_string_lossy()))
            }
        };
        std::fs::create_dir_all(&keep)?;

        let phase = Instant::now();
        let (commit, commit_s) = git::resolve(&git_dir, &rev)?;
        let listing = keep.join("trees").join(&commit);
        // A listing kept from an earlier mount of this commit means its blobs were all fetched
        // then: skip the walk of its trees.
        let missing = if listing.exists() { 0 } else { fill_missing(&git_dir, &commit)? };
        let fetch_ms = ms(phase);

        let phase = Instant::now();
        let mut items = git::ls_tree_cached(&git_dir, &commit, &listing)?;
        if let Some(sparse) = &args.sparse {
            let folders = sparse_folders(&std::fs::read_to_string(sparse)?);
            items.retain(|item| in_cone(&item.path, &folders));
        }
        let links = git::link_texts(&git_dir, &items)?;
        let ls_tree_ms = ms(phase);

        let phase = Instant::now();
        let book_file = keep.join("book");
        let mut book = Book::load(&book_file);
        let now_s = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let layout = Layout {
            commit_ns: commit_s.saturating_mul(1_000_000_000),
            now_ns: i64::try_from(now_s.saturating_sub(1))?.saturating_mul(1_000_000_000),
            gitfile: None,
            real_root: None,
            links: &links,
        };
        let projection = Projection::build(&commit, &items, &mut book, &layout)?;
        let build_ms = ms(phase);

        let phase = Instant::now();
        // SAFETY: getuid and getgid cannot fail.
        let owner = unsafe { (libc::getuid(), libc::getgid()) };
        let index = git::index_bytes(&projection.index, owner.0, owner.1)?;
        if let Some(parent) = index_file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temp = index_file.with_extension(format!("tmp{}", std::process::id()));
        std::fs::write(&temp, &index)?;
        std::fs::rename(&temp, &index_file)?;
        book.save(&book_file)?;
        let index_ms = ms(phase);

        let phase = Instant::now();
        let entries = projection.manifest.len();
        let files = projection.index.len();
        let blobs = Arc::new(GitBlobs::new(&git_dir, projection.sources));
        let state = keep.join("state");
        let overlay = Arc::new(Overlay::open(Arc::new(projection.manifest), &state, blobs, owner)?);
        mount::unmount_stale(&at);
        let ready = args.ready_file.clone();
        let walked = at.clone();
        let options = mount::Options {
            read_only: true,
            allow_other: args.allow_other,
            ..mount::Options::default()
        };
        mount::serve_with(overlay, &at, options, move || {
            let line = format!(
                "{{\"commit\":\"{commit}\",\"entries\":{entries},\"files\":{files},\
                 \"missing_fetched\":{missing},\"fetch_ms\":{fetch_ms},\
                 \"ls_tree_ms\":{ls_tree_ms},\"build_ms\":{build_ms},\"index_ms\":{index_ms},\
                 \"mount_ms\":{},\"total_ms\":{}}}",
                ms(phase),
                ms(started),
            );
            eprintln!("{line}");
            if let Some(ready) = ready {
                let _ = std::fs::write(ready, format!("{line}\n"));
            }
            // Fill the kernel's entry, attribute and listing caches now, in the background: the
            // first `git status` or `find` over the lower (through any overlay on it) then makes
            // no round trip here, as the second always did.
            let _ = std::thread::Builder::new()
                .name("projection-warm".into())
                .spawn(move || warm(&walked));
        })
    }

    /// Lists every folder under `dir` and reads every entry's attributes.
    fn warm(dir: &Path) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                warm(&entry.path());
            } else {
                let _ = entry.metadata();
            }
        }
    }

    fn git_mount(args: &Args, at: &Path) -> anyhow::Result<()> {
        let started = Instant::now();
        let git_dir =
            args.git_dir.clone().ok_or_else(|| anyhow::anyhow!("--git-dir is required"))?;
        let git_dir = git_dir.canonicalize()?;
        let rev = args.commit.clone().ok_or_else(|| anyhow::anyhow!("--commit is required"))?;
        // A mount whose server died (SIGKILL, an OOM kill, a crash) answers every call at `at` with
        // ENOTCONN, so `create_dir_all` fails with EEXIST and a restart could never mount there
        // again: detach the dead one first. A live mount answers, and is left to `serve`'s own
        // `unmount_stale` as before.
        if std::fs::metadata(at).is_err_and(|error| error.raw_os_error() == Some(libc::ENOTCONN)) {
            mount::unmount_stale(at);
        }
        std::fs::create_dir_all(at)?;
        let at = at.canonicalize()?;
        let at_text = at.to_string_lossy().into_owned();
        let keep = match &args.keep {
            Some(keep) => keep.clone(),
            None => {
                let home = std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("no HOME"))?;
                PathBuf::from(home).join(".cache/cmux-projection").join(hash(&at_text))
            }
        };
        std::fs::create_dir_all(&keep)?;
        let name = args.name.clone().unwrap_or_else(|| format!("projected-{}", hash(&at_text)));

        let phase = Instant::now();
        let (commit, commit_s) = git::resolve(&git_dir, &rev)?;
        let listing = keep.join("trees").join(&commit);
        // A listing kept from an earlier mount of this commit means its blobs were all fetched
        // then: skip the walk of its trees.
        let missing = if listing.exists() { 0 } else { fill_missing(&git_dir, &commit)? };
        let fetch_ms = ms(phase);

        let phase = Instant::now();
        let items = git::ls_tree_cached(&git_dir, &commit, &listing)?;
        let links = git::link_texts(&git_dir, &items)?;
        let ls_tree_ms = ms(phase);

        let phase = Instant::now();
        let book_file = keep.join("book");
        let mut book = Book::load(&book_file);
        let admin = git_dir.join("worktrees").join(&name);
        let real_root = keep.join("real");
        // New content is a second older than now, so git never finds it racily clean against the
        // index written just after (and cargo still sees it newer than any earlier build).
        let now_s = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let layout = Layout {
            commit_ns: commit_s.saturating_mul(1_000_000_000),
            now_ns: i64::try_from(now_s.saturating_sub(1))?.saturating_mul(1_000_000_000),
            gitfile: Some(Worktree::gitfile(&admin)),
            real_root: Some(&real_root),
            links: &links,
        };
        let projection = Projection::build(&commit, &items, &mut book, &layout)?;
        for real in &projection.real_dirs {
            std::fs::create_dir_all(real_root.join(real))?;
        }
        let build_ms = ms(phase);

        let phase = Instant::now();
        let state = keep.join("state");
        if args.fresh && state.exists() {
            std::fs::remove_dir_all(&state)?;
        }
        // SAFETY: getuid and getgid cannot fail.
        let owner = unsafe { (libc::getuid(), libc::getgid()) };
        if args.fresh || !admin.join("index").exists() {
            let index = git::index_bytes(&projection.index, owner.0, owner.1)?;
            Worktree::write(&git_dir, &name, &at, &commit, &index, &projection.real_dirs)?;
        }
        book.save(&book_file)?;
        let index_ms = ms(phase);

        let phase = Instant::now();
        let entries = projection.manifest.len();
        let files = projection.index.len();
        let blobs = Arc::new(GitBlobs::new(&git_dir, projection.sources));
        let overlay = Arc::new(Overlay::open(Arc::new(projection.manifest), &state, blobs, owner)?);
        mount::unmount_stale(&at);
        let ready = args.ready_file.clone();
        mount::serve(overlay, &at, move || {
            let line = format!(
                "{{\"commit\":\"{commit}\",\"entries\":{entries},\"files\":{files},\
                 \"missing_fetched\":{missing},\"fetch_ms\":{fetch_ms},\
                 \"ls_tree_ms\":{ls_tree_ms},\"build_ms\":{build_ms},\"index_ms\":{index_ms},\
                 \"mount_ms\":{},\"total_ms\":{}}}",
                ms(phase),
                ms(started),
            );
            eprintln!("{line}");
            if let Some(ready) = ready {
                let _ = std::fs::write(ready, format!("{line}\n"));
            }
        })
    }
}
