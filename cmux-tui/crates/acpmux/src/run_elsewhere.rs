//! "Run on a bigger machine" (wow idea 43): a chat's slow command runs again on a machine the
//! person already connected, in the same repository at the same commit, and its output streams
//! back under the original row (`server/run_elsewhere.rs` serves it; the web row reads the task
//! with `_acpmux/bg/output`).
//!
//! What goes is the working tree as git sees it, never a copy of the folder: the newest commit the
//! repository's upstream already has (the base), plus `git diff --binary <base>` of the tracked
//! files, which carries both unpushed commits and uncommitted edits. Untracked files stay here and
//! are listed as staying. A file that looks like a secret (by name, or a private key in its added
//! lines) is left out unless the person names it; the plan lists every file before anything goes,
//! and a start whose tree changed since that plan is refused (`Plan::digest`).
//!
//! The other machine is an `ssh://` peer: the run is a local background task of the chat whose
//! command is `ssh <peer> bash -s` fed a script ([`remote_script`]) that clones the repository
//! once into the peer's cache, checks out the base in a reusable worktree, applies the diff and
//! runs the command there. The person's own ssh does the work, so the peer serves nothing new.

use sha2::{Digest as _, Sha256};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The longest command offered a run elsewhere.
const MAX_COMMAND: usize = 4096;
/// The largest diff sent: a bigger one is a sign of build output tracked by mistake.
pub const MAX_PATCH: usize = 64 << 20;
/// How many untracked paths a plan lists (it counts them all).
const UNTRACKED_LISTED: usize = 50;
/// How long one git call may take before the plan gives up.
const GIT_DEADLINE: Duration = Duration::from_secs(30);

/// Programs that need this machine itself (its screen, its keys, a person at the keyboard) or
/// that reach other machines on their own: a command that starts with one stays here.
const LOCAL_ONLY: &[&str] = &[
    "sudo",
    "su",
    "doas",
    "ssh",
    "scp",
    "sftp",
    "mosh",
    "rsync",
    "vi",
    "vim",
    "nvim",
    "nano",
    "emacs",
    "less",
    "more",
    "man",
    "top",
    "htop",
    "btop",
    "watch",
    "tmux",
    "screen",
    "open",
    "xdg-open",
    "osascript",
    "pbcopy",
    "pbpaste",
    "code",
    "cmux",
    "acpmux",
    "security",
    "defaults",
    "launchctl",
    "systemctl",
    "pkill",
    "killall",
];

/// Why `command` stays on this machine, or None when it may run elsewhere. The other machine runs
/// it in its own copy of the repository, so a path into a home folder (this one's, even inside the
/// repository) names a file it does not have.
pub fn command_refusal(command: &str) -> Option<String> {
    let command = command.trim();
    if command.is_empty() {
        return Some("the command is empty".into());
    }
    if command.len() > MAX_COMMAND {
        return Some("the command is too long to send".into());
    }
    if command.contains('\0') {
        return Some("the command has a NUL byte".into());
    }
    for program in programs(command) {
        if LOCAL_ONLY.contains(&program.as_str()) {
            return Some(format!("{program} needs this machine"));
        }
    }
    let lower = command.to_ascii_lowercase();
    if ["localhost", "127.0.0.1", "[::1]", "0.0.0.0"].iter().any(|h| lower.contains(h)) {
        return Some("it talks to a service on this machine".into());
    }
    for word in command.split(|c: char| c.is_whitespace() || matches!(c, '=' | '"' | '\'')) {
        if word.starts_with("~/") || word == "~" || word.starts_with("$HOME") {
            return Some("it names a file in your home folder".into());
        }
        if word.starts_with("/Users/") || word.starts_with("/home/") {
            return Some(
                "it names a path on this machine; use one relative to the repository".into(),
            );
        }
    }
    None
}

/// The program each simple command of a pipeline or list starts with, past `VAR=value`
/// assignments, `env`, `time`, `nice` and `exec`, without a leading path (`/usr/bin/vim`: `vim`).
fn programs(command: &str) -> Vec<String> {
    let mut out = Vec::new();
    let parts = command.split(['|', ';', '&', '\n', '(', ')', '`']).chain(command.split("$("));
    for part in parts {
        let mut words = part.split_whitespace().skip_while(|w| {
            (w.contains('=') && !w.starts_with('='))
                || matches!(*w, "env" | "time" | "nice" | "exec" | "command" | "then" | "do")
        });
        if let Some(first) = words.next() {
            let name = first.rsplit('/').next().unwrap_or(first);
            out.push(name.trim_matches(['"', '\'']).to_owned());
        }
    }
    out
}

/// Whether `path` is named like a secret: an env file (not its example), a key or certificate
/// bundle, a credentials or token file.
pub fn secret_name(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path).to_ascii_lowercase();
    // Every `.env*` (`.env.local`, `.envrc`, `.env-prod`) but the examples.
    if name.starts_with(".env") && !example(&name) {
        return true;
    }
    if name.starts_with("id_rsa")
        || name.starts_with("id_ed25519")
        || name.starts_with("id_ecdsa")
        || name.starts_with("credentials")
        || name.starts_with("secrets.")
    {
        return !example(&name);
    }
    let ext = name.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
    matches!(ext, "pem" | "key" | "p12" | "pfx" | "keystore" | "jks" | "ppk")
        || matches!(name.as_str(), ".npmrc" | ".netrc" | ".pypirc" | ".git-credentials")
}

fn example(name: &str) -> bool {
    ["example", "sample", "template", "dist"].iter().any(|w| name.contains(w))
}

/// One file's part of a diff: its path, git's letter for it and its bytes.
pub struct Section<'a> {
    pub path: String,
    pub status: &'static str,
    pub bytes: &'a [u8],
}

/// `patch` cut at each `diff --git` line. The file list, the secrets and what a run sends all
/// come from these, so they always describe the same read of the tree.
pub fn sections(patch: &[u8]) -> Vec<Section<'_>> {
    let mut starts = Vec::new();
    let mut at = 0usize;
    for line in patch.split_inclusive(|b| *b == b'\n') {
        if line.starts_with(b"diff --git ") {
            starts.push(at);
        }
        at = at.saturating_add(line.len());
    }
    starts
        .iter()
        .enumerate()
        .filter_map(|(i, &start)| {
            let end = starts.get(i.saturating_add(1)).copied().unwrap_or(patch.len());
            let bytes = patch.get(start..end)?;
            let text = String::from_utf8_lossy(bytes);
            let mut lines = text.lines();
            let path = header_path(lines.next()?.strip_prefix("diff --git ")?)?;
            let mut status = "M";
            for l in
                lines.take_while(|l| !l.starts_with("@@") && !l.starts_with("GIT binary patch"))
            {
                if l.starts_with("new file mode") {
                    status = "A";
                } else if l.starts_with("deleted file mode") {
                    status = "D";
                }
            }
            Some(Section { path, status, bytes })
        })
        .collect()
}

/// The path in a `diff --git` line's `a/P b/P`. With no renames both halves name one file, so an
/// unquoted pair splits at its middle even with spaces in the name; a quoted one is unquoted.
fn header_path(rest: &str) -> Option<String> {
    if rest.starts_with('"') {
        let mut escaped = false;
        let (end, _) = rest.char_indices().skip(1).find(|&(_, c)| {
            let closes = c == '"' && !escaped;
            escaped = c == '\\' && !escaped;
            closes
        })?;
        return unquote(rest.get(..=end)?)?.strip_prefix("a/").map(str::to_owned);
    }
    let half = rest.len().checked_sub(1)?.checked_div(2)?;
    rest.get(..half)?.strip_prefix("a/").map(str::to_owned)
}

/// `patch` without the sections of `left_out`.
pub fn patch_without(patch: &[u8], left_out: &[String]) -> Vec<u8> {
    sections(patch)
        .iter()
        .filter(|s| !left_out.contains(&s.path))
        .flat_map(|s| s.bytes.iter().copied())
        .collect()
}

/// Whether a section's added lines carry a private key or a well-known token shape.
fn adds_a_secret(section: &[u8]) -> bool {
    let text = String::from_utf8_lossy(section);
    text.lines().skip_while(|l| !l.starts_with("@@")).filter_map(|l| l.strip_prefix('+')).any(
        |added| {
            // A few shapes no code has by accident; a false hit would leave a needed file out.
            added.contains("PRIVATE KEY-----")
                || ["ghp_", "github_pat_", "sk-ant-", "sk-proj-", "xoxb-", "xoxp-"]
                    .iter()
                    .any(|p| token_after(added, p))
                || added.split(|c: char| !c.is_ascii_alphanumeric()).any(|w| {
                    w.len() == 20
                        && w.starts_with("AKIA")
                        && w.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
                })
        },
    )
}

/// The files whose added lines in `patch` carry a private key or a well-known token shape.
#[cfg(test)]
fn secret_content(patch: &[u8]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for s in sections(patch) {
        if adds_a_secret(s.bytes) && !out.contains(&s.path) {
            out.push(s.path);
        }
    }
    out
}

/// A path as git's diff header writes it: as is, or in double quotes with C escapes (`\"`,
/// `\\`, `\t`, octal bytes). None for a quoted name that doesn't parse.
fn unquote(name: &str) -> Option<String> {
    let Some(inner) = name.strip_prefix('"') else { return Some(name.to_owned()) };
    let inner = inner.strip_suffix('"')?;
    let mut bytes = Vec::with_capacity(inner.len());
    let mut it = inner.bytes().peekable();
    while let Some(b) = it.next() {
        if b != b'\\' {
            bytes.push(b);
            continue;
        }
        let c = it.next()?;
        bytes.push(match c {
            b'a' => 7,
            b'b' => 8,
            b't' => b'\t',
            b'n' => b'\n',
            b'v' => 11,
            b'f' => 12,
            b'r' => b'\r',
            b'0'..=b'7' => {
                let digits = [c, it.next()?, it.next()?];
                u8::from_str_radix(std::str::from_utf8(&digits).ok()?, 8).ok()?
            }
            other => other,
        });
    }
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

/// Whether `line` has `prefix` followed by at least 20 token characters.
fn token_after(line: &str, prefix: &str) -> bool {
    line.match_indices(prefix).any(|(i, p)| {
        let Some(rest) = line.get(i..).and_then(|r| r.strip_prefix(p)) else { return false };
        rest.bytes().take_while(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-')).count()
            >= 20
    })
}

/// `url` without a login (`https://user:token@host/x` is `https://host/x`): the other machine
/// fetches with its own credentials, and a token in the URL never leaves this one.
pub fn without_login(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else { return url.to_owned() };
    let (authority, path) =
        rest.find('/').and_then(|i| rest.split_at_checked(i)).unwrap_or((rest, ""));
    match authority.rsplit_once('@') {
        // An ssh user names the account, not a secret (`ssh://git@host/x`); a password goes.
        Some((user, host)) if scheme.eq_ignore_ascii_case("ssh") || scheme.contains("+ssh") => {
            let user = user.split_once(':').map_or(user, |(u, _)| u);
            format!("{scheme}://{user}@{host}{path}")
        }
        Some((_, host)) => format!("{scheme}://{host}{path}"),
        None => url.to_owned(),
    }
}

/// One tracked file the diff carries.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeFile {
    pub path: String,
    /// git's letter: `M`odified, `A`dded, `D`eleted, `T`ype changed.
    pub status: String,
    /// Looks like a secret: left out unless the person names it.
    pub secret: bool,
}

/// What a run elsewhere sends, read from the repository at one moment.
#[derive(Debug, Clone)]
pub struct Plan {
    pub root: PathBuf,
    /// The folder the command runs in, relative to `root` (`""` or `sub/dir/`).
    pub prefix: String,
    pub origin: String,
    /// The newest commit of HEAD the upstream has.
    pub base: String,
    pub files: Vec<TreeFile>,
    pub untracked: Vec<String>,
    pub untracked_total: usize,
    /// `git diff --binary <base>` of every tracked file (no file left out).
    pub patch: Vec<u8>,
}

impl Plan {
    /// Names this exact tree: the base and the whole diff. A start carries the digest the
    /// person saw, and goes only while the tree still has it.
    pub fn digest(&self) -> String {
        let mut h = Sha256::new();
        for part in [&self.origin, &self.prefix, &self.base] {
            h.update(part.as_bytes());
            h.update([0]);
        }
        h.update(&self.patch);
        let d = h.finalize();
        d.iter().take(12).map(|b| format!("{b:02x}")).collect()
    }

    /// The files left out: every secret-looking one but those in `send_secrets`.
    pub fn left_out(&self, send_secrets: &[String]) -> Vec<String> {
        self.files
            .iter()
            .filter(|f| f.secret && !send_secrets.contains(&f.path))
            .map(|f| f.path.clone())
            .collect()
    }

    pub fn view(&self) -> serde_json::Value {
        serde_json::json!({
            "root": self.root,
            "origin": self.origin,
            "prefix": self.prefix,
            "base": self.base,
            "files": self.files,
            "untracked": self.untracked,
            "untrackedTotal": self.untracked_total,
            "patchBytes": self.patch.len(),
            "digest": self.digest(),
        })
    }
}

async fn git(dir: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let mut cmd = tokio::process::Command::new("git");
    cmd.arg("-C")
        .arg(dir)
        .args(["-c", "core.quotepath=off", "-c", "diff.noprefix=false"])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let out = tokio::time::timeout(GIT_DEADLINE, cmd.output())
        .await
        .map_err(|_| format!("git {} took too long", args.first().unwrap_or(&"")))?
        .map_err(|e| format!("git did not start: {e}"))?;
    if !out.status.success() {
        return Err(format!("git {} failed", args.first().unwrap_or(&"")));
    }
    Ok(out.stdout)
}

fn line(bytes: Vec<u8>) -> String {
    String::from_utf8_lossy(&bytes).trim_end_matches(['\n', '\r']).to_owned()
}

/// Read what a run of a command in `cwd` would send. Fails, with a reason the person reads,
/// outside a repository, without an `origin` remote or an upstream it shares a commit with, and
/// on a diff over [`MAX_PATCH`].
pub async fn plan(cwd: &Path) -> Result<Plan, String> {
    let root = line(
        git(cwd, &["rev-parse", "--show-toplevel"])
            .await
            .map_err(|_| "this folder is not in a git repository".to_owned())?,
    );
    let root = PathBuf::from(root);
    let prefix = line(git(cwd, &["rev-parse", "--show-prefix"]).await?);
    let origin = without_login(&line(
        git(&root, &["remote", "get-url", "origin"])
            .await
            .map_err(|_| "the repository has no origin remote".to_owned())?,
    ));
    if origin.starts_with('-') {
        return Err("the origin remote's URL starts with -".into());
    }
    let upstream = match git(&root, &["rev-parse", "--verify", "-q", "@{upstream}"]).await {
        Ok(sha) => line(sha),
        Err(_) => line(
            git(&root, &["rev-parse", "--verify", "-q", "refs/remotes/origin/HEAD"])
                .await
                .map_err(|_| "the branch has no upstream to start from".to_owned())?,
        ),
    };
    let base = line(
        git(&root, &["merge-base", "HEAD", &upstream])
            .await
            .map_err(|_| "HEAD shares no commit with its upstream".to_owned())?,
    );
    // One read: the files and their secrets come from this diff, never from a second look at
    // the index, so nothing staged or unstaged in between goes unseen.
    let patch = diff(&root, &base).await?;
    let mut files: Vec<TreeFile> = Vec::new();
    for section in sections(&patch) {
        let secret =
            section.status != "D" && (secret_name(&section.path) || adds_a_secret(section.bytes));
        match files.iter_mut().find(|f| f.path == section.path) {
            // A type change is a deletion and an addition of one path.
            Some(f) => {
                f.status = "T".into();
                f.secret |= secret;
            }
            None => {
                files.push(TreeFile { path: section.path, status: section.status.into(), secret })
            }
        }
    }
    let others = git(&root, &["ls-files", "-z", "--others", "--exclude-standard"]).await?;
    let others: Vec<&[u8]> = others.split(|b| *b == 0).filter(|p| !p.is_empty()).collect();
    let untracked_total = others.len();
    let untracked = others
        .iter()
        .take(UNTRACKED_LISTED)
        .map(|p| String::from_utf8_lossy(p).into_owned())
        .collect();
    Ok(Plan { root, prefix, origin, base, files, untracked, untracked_total, patch })
}

/// `git diff --binary <base>` of the working tree's tracked files.
pub async fn diff(root: &Path, base: &str) -> Result<Vec<u8>, String> {
    let args: Vec<String> = [
        "diff",
        "--binary",
        "--no-renames",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        base,
        "--",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let patch = git(root, &args).await?;
    if patch.len() > MAX_PATCH {
        return Err(format!(
            "the changes are {} MiB, more than the {} MiB a run sends",
            patch.len().checked_shr(20).unwrap_or(0),
            MAX_PATCH.checked_shr(20).unwrap_or(0)
        ));
    }
    Ok(patch)
}

/// `s` as one single-quoted shell word.
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The peer's cache folder name for a repository: its origin's readable part plus a short hash,
/// so two origins never share one.
fn cache_slug(origin: &str) -> String {
    let tail: String = origin
        .rsplit(['/', ':'])
        .take(2)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>()
        .join("-")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '-' })
        .collect();
    let tail = tail.trim_end_matches(".git").trim_matches(['-', '.']).to_owned();
    let h = Sha256::digest(origin.as_bytes());
    let short: String = h.iter().take(3).map(|b| format!("{b:02x}")).collect();
    format!("{tail}-{short}")
}

/// The script the other machine runs with `bash -s`: clone `origin` once into its cache, check
/// out `base` in a reusable worktree (a second run while one holds it gets its own, removed at
/// its end), apply `patch`, and run `command` in `prefix` under a login shell. Its own lines
/// go to stderr, prefixed `[cmux]`; it exits with the command's code.
pub fn remote_script(
    plan: &Plan,
    patch: &[u8],
    left_out: &[String],
    command: &str,
    run_id: &str,
) -> Result<String, String> {
    let patch = std::str::from_utf8(patch)
        .map_err(|_| "the changes are not text git can send (a non-UTF-8 path?)".to_owned())?;
    let end = format!("CMUX_PATCH_{}", run_id.replace('-', "_"));
    if patch.lines().any(|l| l == end) {
        return Err("the changes hold the script's end marker".into());
    }
    let short = plan.base.get(..12).unwrap_or(&plan.base);
    let mut s = String::new();
    s.push_str("set -eu\n");
    s.push_str(&format!(
        "origin={}\nbase={}\nprefix={}\nslug={}\nrun={}\n",
        shell_quote(&plan.origin),
        shell_quote(&plan.base),
        shell_quote(&plan.prefix),
        shell_quote(&cache_slug(&plan.origin)),
        shell_quote(run_id),
    ));
    s.push_str(
        r#"say() { printf '[cmux] %s\n' "$*" >&2; }
command -v git >/dev/null 2>&1 || { say "git is not installed on $(hostname)"; exit 127; }
cache="${XDG_CACHE_HOME:-$HOME/.cache}/cmux-run-elsewhere/$slug"
mkdir -p "$cache"
repo="$cache/repo.git"
if [ ! -d "$repo" ]; then
  say "cloning the repository once into $cache"
  git clone -q --bare --filter=blob:none -- "$origin" "$repo.tmp-$run" 2>/dev/null \
    || git clone -q --bare -- "$origin" "$repo.tmp-$run"
  mv "$repo.tmp-$run" "$repo" 2>/dev/null || rm -rf "$repo.tmp-$run"
fi
if ! git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null; then
  git -C "$repo" fetch -q origin "$base" 2>/dev/null \
    || git -C "$repo" fetch -q origin '+refs/heads/*:refs/heads/*'
fi
# One run at a time holds the shared worktree (mkdir is atomic); another gets its own. A lock
# whose run is gone is cleared at this run's end, so the next run takes it.
lock="$cache/work.lock.d"
if mkdir "$lock" 2>/dev/null; then
  echo $$ > "$lock/pid"
  work="$cache/work"
  done_() { rm -rf "$lock"; }
else
  stale=$(cat "$lock/pid" 2>/dev/null || true)
  work="$cache/run-$run"
  done_() {
    git -C "$repo" worktree remove --force "$work" >/dev/null 2>&1 || rm -rf "$work"
    if [ -n "$stale" ] && ! kill -0 "$stale" 2>/dev/null && [ "$(cat "$lock/pid" 2>/dev/null)" = "$stale" ]; then
      rm -rf "$lock"
    fi
  }
fi
trap done_ EXIT
# The files the last run in the shared worktree brought: one the repository ignores (a sent
# .env) would outlive `git clean` into a run that left it out.
# Each goes only where no folder on its path is a link, so a run that turned `data/` into a link
# never makes this one delete outside the worktree.
# They go before the checkout, so a file the new base itself has is the base's again after it.
if [ -e "$work/.git" ]; then
  if [ -f "$work.sent" ]; then
    while IFS= read -r -d '' p; do
      d=$(dirname -- "$p")
      while [ "$d" != . ] && [ "$d" != / ] && [ ! -L "$work/$d" ]; do d=$(dirname -- "$d"); done
      if [ "$d" = . ]; then rm -f -- "$work/$p"; fi
    done <"$work.sent"
  fi
  git -C "$work" checkout -q -f --detach "$base"
  git -C "$work" clean -fdq
else
  rm -rf "$work"
  git -C "$repo" worktree prune
  git -C "$repo" worktree add -q -f --detach "$work" "$base"
fi
"#,
    );
    if !patch.is_empty() {
        s.push_str(&format!(
            "git -C \"$work\" apply --whitespace=nowarn --binary - <<'{end}'\n{patch}{nl}{end}\n",
            nl = if patch.ends_with('\n') { "" } else { "\n" },
        ));
    }
    // Only the files the base doesn't have: checkout restores the rest.
    let sent: Vec<String> = plan
        .files
        .iter()
        .filter(|f| f.status == "A" && !left_out.contains(&f.path))
        .map(|f| shell_quote(&f.path))
        .collect();
    s.push_str("if [ \"$work\" = \"$cache/work\" ]; then\n");
    if sent.is_empty() {
        s.push_str("  : >\"$work.sent\"\n");
    } else {
        s.push_str(&format!("  printf '%s\\0' {} >\"$work.sent\"\n", sent.join(" ")));
    }
    s.push_str("fi\n");
    s.push_str(&format!(
        "say \"running on $(hostname) at {short} with {n} changed file(s)\"\ncd \"$work/$prefix\"\nset +e\ncmd={cmd}\n",
        n = plan.files.len(),
        cmd = shell_quote(command),
    ));
    // The command runs in its own process group, its stdin empty (the script is this shell's).
    // ssh gives it no terminal, so a dropped connection (Stop here, a closed laptop) sends it no
    // hangup: a watcher sees this shell lose its parent and ends the group, then stops itself.
    s.push_str(
        r#"set -m
bash -lc "$cmd" </dev/null &
child=$!
set +m
parent=$PPID
(
  while kill -0 "$child" 2>/dev/null; do
    if [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != "$parent" ]; then
      kill -TERM -- "-$child" 2>/dev/null
      sleep 5
      kill -KILL -- "-$child" 2>/dev/null
      exit 0
    fi
    sleep 2
  done
) </dev/null >/dev/null 2>&1 &
wait "$child"
exit $?
"#,
    );
    Ok(s)
}

/// The local command a run's background task runs: `program` (ssh) to `destination` with the
/// script on stdin, then the script removed; it exits with the remote command's code.
pub fn task_command(program: &str, destination: &str, script: &Path) -> String {
    let script = shell_quote(&script.to_string_lossy());
    format!(
        "{program} -T -o BatchMode=yes -o ConnectTimeout=20 -- {dest} 'bash -s' < {script}; rc=$?; rm -f {script}; exit $rc",
        program = shell_quote(program),
        dest = shell_quote(destination),
    )
}

#[cfg(test)]
#[path = "run_elsewhere_tests.rs"]
mod tests;
