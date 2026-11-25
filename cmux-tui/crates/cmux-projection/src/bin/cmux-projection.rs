//! `cmux-projection`: a projected checkout of a git commit, on a lane VM (FUSE) or a Mac (NFSv3
//! from localhost, `cmux_projection::nfs`: no kernel or app extension, no prompt).
//!
//! ```text
//! cmux-projection git-mount --git-dir MIRROR --commit REV --at PATH [--keep DIR] [--fresh]
//!                           [--name NAME] [--ready-file FILE] [--sparse FILE]
//! cmux-projection git-lower --git-dir MIRROR --commit REV --at PATH --index FILE [--sparse FILE]
//!                           [--keep DIR] [--trees DIR] [--ready-file FILE] [--allow-other]
//! cmux-projection git-unmount --at PATH
//! cmux-projection seed --git-dir MIRROR --listen ADDR [--rate BYTES_PER_S] [--conns N]
//!                      [--yield-lock FILE]... [--heartbeat URL --repo OWNER/NAME
//!                      [--advertise URL] [--zone ZONE]]
//! ```
//!
//! `git-lower` mounts commit REV's tree read only at PATH (every write answers EROFS) for many
//! checkouts to share as the lower layer of their own overlays, and writes its git index to FILE:
//! stat data as the mount serves it, so `git status` over the lower finds every file clean
//! without reading (fetching) it. No `.git`, no worktree, no build output links: each checkout on
//! top keeps its own. `--sparse FILE` (a sparse-checkout pattern file, cone or not) leaves the
//! rest out of the tree and the index. `--trees DIR` (default `KEEP/trees`) holds each commit's
//! listing: lowers of one mirror that share it list a new commit from the last one's sizes. Blobs come as `git-mount`'s do, on first read.
//! `--allow-other` lets other users in, root among them: a kernel overlay mounted with `sudo`
//! reads its lower as root (it needs `user_allow_other` in `/etc/fuse.conf`).
//!
//! `git-mount` mounts commit REV of the bare repo MIRROR at PATH and serves it until PATH is
//! unmounted (`git-unmount`, or `fusermount3 -u PATH` on Linux, `umount PATH` on a Mac). What it writes lands in an upper folder
//! under `--keep` (default `~/.cache/cmux-projection/<hash of PATH>`), which also holds the mtime
//! book and the build output folders (`target/` and the like), so mount the same PATH again and
//! cargo finds its last build fresh. `--fresh` starts a new checkout: the upper folder and the
//! worktree's index are made anew. git sees PATH as a worktree of MIRROR named NAME (default
//! `projected-<hash of PATH>`). Once the mount is up it prints one JSON line of timings on stderr
//! and writes it to `--ready-file`. `--sparse FILE` checks out only what FILE's non-cone sparse
//! patterns keep (one a line, as `git sparse-checkout set --no-cone --stdin` reads them): the rest
//! is not projected, its index entries are skip-worktree, and the worktree records the patterns
//! as git does, so `git status` stays clean and `git sparse-checkout list` prints them.
//!
//! The blobs MIRROR lacks are first asked of the fleet's seeds, the controller SSD and R2 that the
//! environment names, each answer checked against its id (`cmux_projection::peers`, hq RFD 0008),
//! and only the rest come from GitHub; `CMUX_PROJECTION_PEERS=0` sends them all to GitHub. `seed` serves MIRROR's blobs read only on ADDR
//! (a tailnet or VPC address, never 0.0.0.0) for the other hosts' chains, answering busy while a
//! `--yield-lock` is held or a GitHub Actions job runs on the host. With `--heartbeat` (the
//! controller's `POST /v1/seeds/heartbeat`) it tells the controller's seed index every minute that
//! it holds `--repo`, reachable at `--advertise` (default `http://ADDR`), in `--zone`. The
//! environment fills what the flags leave out: `CMUX_PROJECTION_SEED_RATE`,
//! `CMUX_PROJECTION_SEED_YIELD_LOCKS` (colon-separated), `CMUX_PROJECTION_SEED_HEARTBEAT_URL`,
//! `CMUX_PROJECTION_SEED_TOKEN_FILE` (the heartbeat's bearer token), `CMUX_PROJECTION_SEED_REPO`
//! and `CMUX_PROJECTION_ZONE`.
//! `s3-push` puts MIRROR's blobs into an S3-compatible bucket. It signs each HEAD and PUT with
//! the configured store keys, skips blobs already held, and prints one JSON result line.

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn main() -> std::process::ExitCode {
    match cli::run(std::env::args().skip(1).collect()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-projection: {error:#}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn main() -> std::process::ExitCode {
    eprintln!("cmux-projection: mounts are Linux and macOS only");
    std::process::ExitCode::from(2)
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
mod cli {
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::{Instant, SystemTime, UNIX_EPOCH};

    use cmux_projection::git::{self, Book, GitBlobs, Layout, Projection, Worktree};
    #[cfg(target_os = "linux")]
    use cmux_projection::mount;
    #[cfg(target_os = "macos")]
    use cmux_projection::nfs as mount;
    use cmux_projection::overlay::Overlay;
    use cmux_projection::peers::{self, Chain, SeedLimits};

    use cmux_projection::sparse::Sparse;

    const USAGE: &str = "usage: cmux-projection git-mount --git-dir MIRROR --commit REV --at PATH \
                         [--keep DIR] [--fresh] [--name NAME] [--ready-file FILE] [--sparse FILE]\n       \
                         cmux-projection git-lower --git-dir MIRROR --commit REV --at PATH \
                         --index FILE [--sparse FILE] [--keep DIR] [--trees DIR] [--ready-file FILE] [--allow-other]\n       \
                         cmux-projection git-unmount --at PATH\n       \
                         cmux-projection seed --git-dir MIRROR --listen ADDR [--rate BYTES_PER_S] \
                         [--conns N] [--yield-lock FILE]... [--heartbeat URL --repo OWNER/NAME \
                         [--advertise URL] [--zone ZONE]]\n       \
                         cmux-projection s3-push --git-dir MIRROR --to BASE [--commit REV]";

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
        trees: Option<PathBuf>,
        listen: Option<String>,
        rate: Option<u64>,
        conns: Option<usize>,
        to: Option<String>,
        yield_locks: Vec<PathBuf>,
        heartbeat: Option<String>,
        advertise: Option<String>,
        zone: Option<String>,
        repo: Option<String>,
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
                "--trees" => parsed.trees = Some(value.into()),
                "--listen" => parsed.listen = Some(value.clone()),
                "--rate" => parsed.rate = Some(value.parse()?),
                "--conns" => parsed.conns = Some(value.parse()?),
                "--to" => parsed.to = Some(value.clone()),
                "--yield-lock" => parsed.yield_locks.push(value.into()),
                "--heartbeat" => parsed.heartbeat = Some(value.clone()),
                "--advertise" => parsed.advertise = Some(value.clone()),
                "--zone" => parsed.zone = Some(value.clone()),
                "--repo" => parsed.repo = Some(value.clone()),
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
        if command == "s3-push" {
            return s3_push(&args);
        }
        let at = args.at.clone().ok_or_else(|| anyhow::anyhow!("--at is required\n{USAGE}"))?;
        match command.as_str() {
            "git-mount" => git_mount(&args, &at),
            "git-lower" => git_lower(&args, &at),
            "git-unmount" => {
                #[cfg(target_os = "linux")]
                let (program, flags): (&str, &[&str]) = ("fusermount3", &["-u"]);
                #[cfg(target_os = "macos")]
                let (program, flags): (&str, &[&str]) = ("/sbin/umount", &[]);
                let status = std::process::Command::new(program).args(flags).arg(&at).status()?;
                anyhow::ensure!(status.success(), "{program} {} failed", at.display());
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
        let env = |name: &str| std::env::var(name).ok().filter(|value| !value.trim().is_empty());
        let mut limits = SeedLimits::default();
        if let Some(rate) =
            args.rate.or_else(|| env("CMUX_PROJECTION_SEED_RATE")?.trim().parse().ok())
        {
            limits.rate = rate;
        }
        if let Some(conns) = args.conns {
            limits.conns = conns;
        }
        limits.yield_locks.clone_from(&args.yield_locks);
        if let Some(locks) = env("CMUX_PROJECTION_SEED_YIELD_LOCKS") {
            limits
                .yield_locks
                .extend(locks.split(':').filter(|lock| !lock.is_empty()).map(PathBuf::from));
        }
        let git_dir = git_dir.canonicalize()?;
        if let Some(url) =
            args.heartbeat.clone().or_else(|| env("CMUX_PROJECTION_SEED_HEARTBEAT_URL"))
        {
            let repo =
                args.repo.clone().or_else(|| env("CMUX_PROJECTION_SEED_REPO")).ok_or_else(
                    || anyhow::anyhow!("--heartbeat needs --repo OWNER/NAME\n{USAGE}"),
                )?;
            let seed_url = args.advertise.clone().unwrap_or_else(|| format!("http://{addr}"));
            let zone =
                args.zone.clone().or_else(|| env("CMUX_PROJECTION_ZONE")).unwrap_or_default();
            let token = env("CMUX_PROJECTION_SEED_TOKEN_FILE")
                .and_then(|file| std::fs::read_to_string(file).ok())
                .map(|token| token.trim().to_owned());
            let host = std::fs::read_to_string("/proc/sys/kernel/hostname")
                .map(|host| host.trim().to_owned())
                .unwrap_or_default();
            let beat = || peers::Beat {
                host: host.clone(),
                seed_url: seed_url.clone(),
                zone: zone.clone(),
                repos: vec![peers::beat_repo(&git_dir, &repo)],
            };
            // Bound first, so a port already taken fails the seed before it is advertised.
            let listener = std::net::TcpListener::bind(&listen)?;
            std::thread::scope(|scope| {
                scope.spawn(|| peers::heartbeat(&url, token.as_deref(), &beat));
                peers::serve_on(&git_dir, listener, &limits);
            });
            return Ok(());
        }
        peers::serve(&git_dir, &listen, limits)
    }

    /// How many blobs `s3-push` reads and sends at once.
    const PUSH_WORKERS: usize = 8;

    fn s3_push(args: &Args) -> anyhow::Result<()> {
        use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};

        use cmux_projection::git::ObjectReader;
        use cmux_projection::s3::{Config, Pushed, Store};

        let started = Instant::now();
        let git_dir = args
            .git_dir
            .clone()
            .ok_or_else(|| anyhow::anyhow!("--git-dir is required\n{USAGE}"))?
            .canonicalize()?;
        let to = args.to.clone().ok_or_else(|| anyhow::anyhow!("--to is required\n{USAGE}"))?;
        let store = Store::new(Config::push_target_from_env(&to).map_err(anyhow::Error::msg)?)?;
        let mut oids: Vec<String> = match &args.commit {
            Some(rev) => {
                let (commit, _) = git::resolve(&git_dir, rev)?;
                git::ls_tree(&git_dir, &commit)?
                    .into_iter()
                    .filter(|item| item.mode != 0o160_000)
                    .map(|item| item.oid)
                    .collect()
            }
            None => std::io::read_to_string(std::io::stdin())?
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(str::to_owned)
                .collect(),
        };
        oids.sort_unstable();
        oids.dedup();
        let (next, stored, had, failed, bytes) = (
            AtomicUsize::new(0),
            AtomicUsize::new(0),
            AtomicUsize::new(0),
            AtomicUsize::new(0),
            AtomicU64::new(0),
        );
        let denied = AtomicBool::new(false);
        // Every reader starts before any work, so a store that can't be read fails the push
        // instead of leaving blobs unsent behind a count of zero failures.
        let readers = (0..PUSH_WORKERS.min(oids.len()))
            .map(|_| ObjectReader::spawn(&git_dir))
            .collect::<anyhow::Result<Vec<_>>>()?;
        std::thread::scope(|scope| {
            for mut reader in readers {
                let (next, stored, had, failed, bytes, denied, oids, store) =
                    (&next, &stored, &had, &failed, &bytes, &denied, &oids, &store);
                scope.spawn(move || {
                    while !denied.load(Ordering::Relaxed) {
                        let Some(oid) = oids.get(next.fetch_add(1, Ordering::Relaxed)) else {
                            return;
                        };
                        let result = reader
                            .blob(oid)
                            .ok_or_else(|| anyhow::anyhow!("{oid}: not in the mirror"))
                            .and_then(|blob| Ok((store.push(oid, &blob)?, blob.len())));
                        match result {
                            Ok((Pushed::Stored, len)) => {
                                stored.fetch_add(1, Ordering::Relaxed);
                                bytes.fetch_add(
                                    u64::try_from(len).unwrap_or(u64::MAX),
                                    Ordering::Relaxed,
                                );
                            }
                            Ok((Pushed::Had, _)) => {
                                had.fetch_add(1, Ordering::Relaxed);
                            }
                            // Keys that may not write refuse every blob: stop on the first.
                            Ok((Pushed::Denied(status), _)) => {
                                failed.fetch_add(1, Ordering::Relaxed);
                                if !denied.swap(true, Ordering::Relaxed) {
                                    eprintln!(
                                        "cmux-projection: s3-push: {} answered {status}; stopped",
                                        store.config.base
                                    );
                                }
                            }
                            Err(error) => {
                                if failed.fetch_add(1, Ordering::Relaxed) < 5 {
                                    eprintln!("cmux-projection: s3-push: {error:#}");
                                }
                            }
                        }
                    }
                });
            }
        });
        let (stored, had, failed) = (stored.into_inner(), had.into_inner(), failed.into_inner());
        let unsent = oids.len().saturating_sub(stored + had + failed);
        println!(
            "{{\"blobs\":{},\"stored\":{stored},\"had\":{had},\"failed\":{failed},\
             \"unsent\":{unsent},\"bytes\":{},\"ms\":{}}}",
            oids.len(),
            bytes.into_inner(),
            ms(started)
        );
        anyhow::ensure!(failed + unsent == 0, "{} blobs were not stored", failed + unsent);
        Ok(())
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

    #[cfg(test)]
    #[test]
    fn sparse_rules_decide_as_git_does() -> anyhow::Result<()> {
        let cone = Sparse::parse("/*\n!/*/\n/cmux-tui/\n!/cmux-tui/*/\n/cmux-tui/crates/x/\n")?;
        // wt's own patterns: everything but some folders, one file put back.
        let wt = Sparse::parse("/*\n!/cmux-next-ios/verify/\n!/web/\n/web/package.json\n")?;
        for (path, in_cone, in_wt) in [
            ("README.md", true, true),
            ("cmux-tui/Cargo.toml", true, true),
            ("cmux-tui/crates/Cargo.toml", false, true),
            ("cmux-tui/crates/x/src/lib.rs", true, true),
            ("cmux-tui/crates/y/src/lib.rs", false, true),
            ("cmux-tui/crates/xy/lib.rs", false, true),
            ("cmux-next-ios/verify/a.swift", false, false),
            ("cmux-next-ios/App.swift", false, true),
            ("web/index.ts", false, false),
            ("web/package.json", false, true),
        ] {
            assert_eq!(cone.includes(path), in_cone, "cone {path}");
            assert_eq!(wt.includes(path), in_wt, "wt {path}");
        }
        let names = Sparse::parse("*.md\n")?;
        assert!(names.includes("docs/a.md"));
        assert!(!names.includes("docs/a.rs"));
        Ok(())
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
        let listing = args.trees.clone().unwrap_or_else(|| keep.join("trees")).join(&commit);
        // A listing kept from an earlier mount of this commit means its blobs were all fetched
        // then: skip the walk of its trees.
        let missing = if listing.exists() { 0 } else { fill_missing(&git_dir, &commit)? };
        let fetch_ms = ms(phase);

        let phase = Instant::now();
        let sparse = args.sparse.as_deref().map(Sparse::load).transpose()?;
        let items = git::ls_tree_cached(&git_dir, &commit, &listing)?;
        let (items, skipped) = Sparse::partition(sparse.as_ref(), items);
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
        let index = git::index_bytes_sparse(&projection.index, &skipped, owner.0, owner.1)?;
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
        let listing = args.trees.clone().unwrap_or_else(|| keep.join("trees")).join(&commit);
        // A listing kept from an earlier mount of this commit means its blobs were all fetched
        // then: skip the walk of its trees.
        let missing = if listing.exists() { 0 } else { fill_missing(&git_dir, &commit)? };
        let fetch_ms = ms(phase);

        let phase = Instant::now();
        let sparse = args.sparse.as_deref().map(Sparse::load).transpose()?;
        let items = git::ls_tree_cached(&git_dir, &commit, &listing)?;
        let (items, skipped) = Sparse::partition(sparse.as_ref(), items);
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
        // Other sparse patterns than last time make the index anew too: its skip-worktree bits
        // follow the patterns.
        if args.fresh
            || !admin.join("index").exists()
            || !Worktree::sparse_matches(&admin, sparse.as_ref())
        {
            let index = git::index_bytes_sparse(&projection.index, &skipped, owner.0, owner.1)?;
            Worktree::write(&git_dir, &name, &at, &commit, &index, &projection.real_dirs)?
                .set_sparse(&git_dir, sparse.as_ref())?;
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
