//! `cmux-projection`: a projected checkout of a git commit on a lane VM.
//!
//! ```text
//! cmux-projection git-mount --git-dir MIRROR --commit REV --at PATH [--keep DIR] [--fresh]
//!                           [--name NAME] [--ready-file FILE]
//! cmux-projection git-unmount --at PATH
//! cmux-projection seed --git-dir MIRROR --listen ADDR [--rate BYTES_PER_S] [--conns N]
//! cmux-projection s3-push --git-dir MIRROR --to BASE [--commit REV]
//! ```
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
//! (a tailnet or VPC address, never 0.0.0.0) for the other hosts' chains. `s3-push` puts MIRROR's
//! blobs into an S3-compatible bucket (`cmux_projection::s3`): BASE is everything before `/<id>`
//! in an object's URL (`https://ENDPOINT/BUCKET/objects`, the `base` of the store the chain reads),
//! signed with that store's keys, else the `CMUX_PROJECTION_S3_*` / `AWS_*` ones. It puts every blob
//! of REV's tree, or the ids on stdin (one per line), skips the ones the bucket holds (one `HEAD`
//! each), refuses bytes that do not hash to their id, and prints one JSON line.

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
                         cmux-projection git-unmount --at PATH\n       \
                         cmux-projection seed --git-dir MIRROR --listen ADDR [--rate BYTES_PER_S] \
                         [--conns N]\n       \
                         cmux-projection s3-push --git-dir MIRROR --to BASE [--commit REV]";

    #[derive(Default)]
    struct Args {
        git_dir: Option<PathBuf>,
        commit: Option<String>,
        at: Option<PathBuf>,
        keep: Option<PathBuf>,
        name: Option<String>,
        ready_file: Option<PathBuf>,
        listen: Option<String>,
        rate: Option<u64>,
        conns: Option<usize>,
        to: Option<String>,
        fresh: bool,
    }

    fn parse(args: &[String]) -> anyhow::Result<Args> {
        let mut parsed = Args::default();
        let mut at = 0;
        while at < args.len() {
            let Some(flag) = args.get(at).map(String::as_str) else { break };
            if flag == "--fresh" {
                parsed.fresh = true;
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
                "--listen" => parsed.listen = Some(value.clone()),
                "--rate" => parsed.rate = Some(value.parse()?),
                "--conns" => parsed.conns = Some(value.parse()?),
                "--to" => parsed.to = Some(value.clone()),
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

    fn git_mount(args: &Args, at: &Path) -> anyhow::Result<()> {
        let started = Instant::now();
        let git_dir =
            args.git_dir.clone().ok_or_else(|| anyhow::anyhow!("--git-dir is required"))?;
        let git_dir = git_dir.canonicalize()?;
        let rev = args.commit.clone().ok_or_else(|| anyhow::anyhow!("--commit is required"))?;
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
        let missing = git::missing(&git_dir, &commit)?;
        let rest = match Chain::from_env() {
            Some(chain) => {
                let (rest, filled) =
                    chain.fill(&missing, &|oid, bytes| peers::write_loose(&git_dir, oid, bytes));
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
        git::fetch_missing(&git_dir, &rest)?;
        let fetch_ms = ms(phase);

        let phase = Instant::now();
        let items = git::ls_tree(&git_dir, &commit)?;
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
            real_root: &real_root,
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
                 \"missing_fetched\":{},\"fetch_ms\":{fetch_ms},\"ls_tree_ms\":{ls_tree_ms},\
                 \"build_ms\":{build_ms},\"index_ms\":{index_ms},\"mount_ms\":{},\
                 \"total_ms\":{}}}",
                missing.len(),
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
