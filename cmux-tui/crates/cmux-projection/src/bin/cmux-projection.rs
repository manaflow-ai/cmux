//! `cmux-projection`: a projected checkout of a git commit on a lane VM.
//!
//! ```text
//! cmux-projection git-mount --git-dir MIRROR --commit REV --at PATH [--keep DIR] [--fresh]
//!                           [--name NAME] [--ready-file FILE]
//! cmux-projection git-lower --git-dir MIRROR --commit REV --at PATH --index FILE [--sparse FILE]
//!                           [--keep DIR] [--trees DIR] [--ready-file FILE] [--allow-other]
//! cmux-projection git-unmount --at PATH
//! cmux-projection seed --git-dir MIRROR --listen ADDR [--rate BYTES_PER_S] [--conns N]
//! cmux-projection s3-push --git-dir MIRROR --to BASE [--commit REV]
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
//! blobs into an S3-compatible bucket at BASE (`https://ENDPOINT/BUCKET[/PREFIX]`, the same value
//! the chain reads as `CMUX_PROJECTION_S3_URL`, with the same key): every blob of REV's tree, or
//! the ids on stdin, one per line. A blob the bucket holds is not sent again. It prints one JSON line.

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
                         --index FILE [--sparse FILE] [--keep DIR] [--trees DIR] [--ready-file FILE] [--allow-other]\n       \
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
        index: Option<PathBuf>,
        sparse: Option<PathBuf>,
        trees: Option<PathBuf>,
        listen: Option<String>,
        rate: Option<u64>,
        conns: Option<usize>,
        to: Option<String>,
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

    fn s3_push(args: &Args) -> anyhow::Result<()> {
        use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

        use cmux_projection::git::ObjectReader;
        use cmux_projection::s3::{Bucket, Put};

        let started = Instant::now();
        let git_dir = args
            .git_dir
            .clone()
            .ok_or_else(|| anyhow::anyhow!("--git-dir is required\n{USAGE}"))?
            .canonicalize()?;
        let to = args.to.clone().ok_or_else(|| anyhow::anyhow!("--to is required\n{USAGE}"))?;
        let key = peers::s3_key_from_env().ok_or_else(|| {
            anyhow::anyhow!(
                "no bucket key: CMUX_PROJECTION_S3_KEY_FILE, or AWS_ACCESS_KEY_ID and \
                 AWS_SECRET_ACCESS_KEY"
            )
        })?;
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
        let bucket = Bucket::new(&to, key)?;
        let (next, stored, had, failed, bytes) = (
            AtomicUsize::new(0),
            AtomicUsize::new(0),
            AtomicUsize::new(0),
            AtomicUsize::new(0),
            AtomicU64::new(0),
        );
        // Every reader starts before any work, so a store that can't be read fails the push
        // instead of leaving blobs unsent behind a count of zero failures.
        let readers = (0..8.min(oids.len()))
            .map(|_| ObjectReader::spawn(&git_dir))
            .collect::<anyhow::Result<Vec<_>>>()?;
        std::thread::scope(|scope| {
            for mut reader in readers {
                let (next, stored, had, failed, bytes, oids, bucket) =
                    (&next, &stored, &had, &failed, &bytes, &oids, &bucket);
                scope.spawn(move || {
                    loop {
                        let Some(oid) = oids.get(next.fetch_add(1, Ordering::Relaxed)) else {
                            return;
                        };
                        let result = reader
                            .blob(oid)
                            .ok_or_else(|| anyhow::anyhow!("{oid}: not in the mirror"))
                            .and_then(|blob| Ok((bucket.put(oid, &blob)?, blob.len())));
                        match result {
                            Ok((Put::Stored, len)) => {
                                stored.fetch_add(1, Ordering::Relaxed);
                                bytes.fetch_add(len as u64, Ordering::Relaxed);
                            }
                            Ok((Put::Had, _)) => {
                                had.fetch_add(1, Ordering::Relaxed);
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
        let failed = failed.into_inner();
        println!(
            "{{\"blobs\":{},\"stored\":{},\"had\":{},\"failed\":{failed},\"bytes\":{},\"ms\":{}}}",
            oids.len(),
            stored.into_inner(),
            had.into_inner(),
            bytes.into_inner(),
            ms(started)
        );
        anyhow::ensure!(failed == 0, "{failed} blobs were not stored");
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
                     {} from R2, {} from the S3 bucket, {} rejected answers, {} sources dropped, \
                     {} left for git",
                    missing.len(),
                    filled.peer,
                    filled.ssd,
                    filled.r2,
                    filled.s3,
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

    /// One line of a sparse-checkout file (`git sparse-checkout set --no-cone`; cone mode writes
    /// the same syntax): `!` negates, a trailing `/` matches folders only, a `/` before the end
    /// anchors it at the top, `*` and `?` match within one path segment.
    struct SparseRule {
        negated: bool,
        folder_only: bool,
        anchored: bool,
        glob: String,
    }

    /// The rules in a sparse-checkout file's `text`, in order (the last that matches decides).
    fn sparse_rules(text: &str) -> Vec<SparseRule> {
        text.lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .filter_map(|line| {
                let (negated, line) =
                    line.strip_prefix('!').map_or((false, line), |rest| (true, rest));
                let folder_only = line.ends_with('/');
                let line = line.trim_end_matches('/');
                let anchored = line.contains('/');
                let glob = line.trim_start_matches('/').to_owned();
                (!glob.is_empty()).then_some(SparseRule { negated, folder_only, anchored, glob })
            })
            .collect()
    }

    /// `text` matches `glob`, where `*` and `?` never match a `/`.
    fn glob_matches(glob: &[u8], text: &[u8]) -> bool {
        match (glob.split_first(), text.split_first()) {
            (None, None) => true,
            (Some((b'*', glob_rest)), _) => {
                glob_matches(glob_rest, text)
                    || text
                        .split_first()
                        .is_some_and(|(&c, text_rest)| c != b'/' && glob_matches(glob, text_rest))
            }
            (Some((b'?', glob_rest)), Some((&c, text_rest))) => {
                c != b'/' && glob_matches(glob_rest, text_rest)
            }
            (Some((g, glob_rest)), Some((c, text_rest))) => {
                g == c && glob_matches(glob_rest, text_rest)
            }
            _ => false,
        }
    }

    /// Whether git checks out `path` (a file) under `rules`, as non-cone sparse checkout decides
    /// it: the deepest of the path and its folders that some rule matches decides, by the last
    /// rule that matches it; a path nothing matches is left out.
    fn sparse_keeps(path: &str, rules: &[SparseRule]) -> bool {
        let mut subject = path;
        let mut folder = false;
        loop {
            let name = subject.rsplit_once('/').map_or(subject, |(_, name)| name);
            let decided = rules.iter().rev().find(|rule| {
                (folder || !rule.folder_only)
                    && if rule.anchored {
                        glob_matches(rule.glob.as_bytes(), subject.as_bytes())
                    } else {
                        glob_matches(rule.glob.as_bytes(), name.as_bytes())
                    }
            });
            if let Some(rule) = decided {
                return !rule.negated;
            }
            match subject.rsplit_once('/') {
                Some((parent, _)) => (subject, folder) = (parent, true),
                None => return false,
            }
        }
    }

    #[cfg(test)]
    #[test]
    fn sparse_rules_decide_as_git_does() {
        let cone = sparse_rules("/*\n!/*/\n/cmux-tui/\n!/cmux-tui/*/\n/cmux-tui/crates/x/\n");
        // wt's own patterns: everything but some folders, one file put back.
        let wt = sparse_rules("/*\n!/cmux-next-ios/verify/\n!/web/\n/web/package.json\n");
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
            assert_eq!(sparse_keeps(path, &cone), in_cone, "cone {path}");
            assert_eq!(sparse_keeps(path, &wt), in_wt, "wt {path}");
        }
        let names = sparse_rules("*.md\n");
        assert!(sparse_keeps("docs/a.md", &names));
        assert!(!sparse_keeps("docs/a.rs", &names));
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
        let mut items = git::ls_tree_cached(&git_dir, &commit, &listing)?;
        let mut skipped = Vec::new();
        if let Some(sparse) = &args.sparse {
            let rules = sparse_rules(&std::fs::read_to_string(sparse)?);
            let (kept, left): (Vec<_>, Vec<_>) =
                items.into_iter().partition(|item| sparse_keeps(&item.path, &rules));
            items = kept;
            skipped = left;
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
