//! `cmux-projection`: a projected checkout of a git commit on a lane VM.
//!
//! ```text
//! cmux-projection git-mount --git-dir MIRROR --commit REV --at PATH [--keep DIR] [--fresh]
//!                           [--name NAME] [--ready-file FILE]
//! cmux-projection git-unmount --at PATH
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

    const USAGE: &str = "usage: cmux-projection git-mount --git-dir MIRROR --commit REV --at PATH \
                         [--keep DIR] [--fresh] [--name NAME] [--ready-file FILE]\n       \
                         cmux-projection git-unmount --at PATH";

    #[derive(Default)]
    struct Args {
        git_dir: Option<PathBuf>,
        commit: Option<String>,
        at: Option<PathBuf>,
        keep: Option<PathBuf>,
        name: Option<String>,
        ready_file: Option<PathBuf>,
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
                _ => anyhow::bail!("unknown flag {flag}\n{USAGE}"),
            }
            at += 2;
        }
        Ok(parsed)
    }

    pub fn run(args: Vec<String>) -> anyhow::Result<()> {
        let (command, rest) = args.split_first().ok_or_else(|| anyhow::anyhow!(USAGE))?;
        let args = parse(rest)?;
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
        git::fetch_missing(&git_dir, &missing)?;
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
