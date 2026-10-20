//! `cmux link stage ssh --to DEST [--port N] [--ssh-binary PATH] --key KEY
//! FOLDER`: puts this Mac's git working copy `FOLDER` on the SSH host `DEST`,
//! so a chat can move there (`cmux link agent move`, cmuxterm-hq#2580). It is
//! the SSH host's counterpart of Move to Cloud's `cmux link sync push`: each
//! kind of machine stages the folder its own way, and the move is the same.
//!
//! 1. Here, a snapshot commit of the working copy is made in a temporary
//!    index: HEAD, every tracked change and every untracked file that is not
//!    ignored. HEAD, the index and the worktree are only read.
//! 2. On the host, `~/work/<repo>` is the repository (made with this Mac's
//!    `origin` when missing; one with another `origin` is refused). HEAD and
//!    the snapshot are pushed there over the user's ssh as
//!    `refs/cmux/moves/<key>/{head,snap}`; only missing objects travel.
//! 3. A new worktree `~/work/cmux-moves/<repo>-<key>` checks out HEAD, takes
//!    the snapshot's files and resets its index to HEAD: the same
//!    uncommitted changes and untracked files as here, on the same branch
//!    when that name is free there. `refs/cmux/moves/<key>/placed` records
//!    what was laid down.
//!
//! A rerun with the same key reuses that worktree while it is exactly as
//! staged (same HEAD, same files), rebuilding it from a newer snapshot when
//! this Mac changed; once it changed there (the moved chat worked in it) the
//! stage refuses (`stage.target_changed`) and never overwrites it. Nothing
//! else on the host is touched.
//!
//! Every ssh runs non-interactively with no forwarding (the app's
//! `SSHCommandLine.enforcedOptions`); the user's ssh config, keys and host
//! key policy apply. Remote scripts go to `sh -s` on stdin, so the login
//! shell only ever sees `sh -s`.
//!
//! Output: one JSON line on stdout, `{"ok":true,"cwd":...,"folder":...,
//! "repo":...,"head":...,"snapshot":...,"branch":...|null,"reused":bool}`
//! (exit 0), where `cwd` is `FOLDER`'s place in the worktree (the chat's
//! `--cwd` for the move); or `{"ok":false,"error":...,"error_code":...}`
//! (exit 1); bad usage exits 64.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use serde_json::json;

const USAGE: &str = "usage: cmux link stage ssh --to DESTINATION [--port PORT] \
[--ssh-binary PATH] --key KEY FOLDER";

/// The app's `SSHCommandLine.enforcedOptions`: no prompts, no forwarding.
const SSH_OPTIONS: &[&str] = &[
    "-oBatchMode=yes",
    "-oConnectTimeout=15",
    "-oForwardAgent=no",
    "-oForwardX11=no",
    "-oClearAllForwardings=yes",
    "-oPermitLocalCommand=no",
];

/// The longest key kept in folder and ref names.
const MAX_KEY: usize = 24;

#[derive(Debug)]
struct Args {
    to: String,
    port: Option<u16>,
    ssh: String,
    key: String,
    folder: PathBuf,
}

#[derive(Debug)]
struct Failed {
    code: &'static str,
    error: String,
}

fn failed(code: &'static str, error: impl Into<String>) -> Failed {
    Failed { code, error: error.into() }
}

/// The staged worktree, as the JSON line reports it.
struct Staged {
    cwd: String,
    folder: String,
    repo: String,
    head: String,
    snapshot: String,
    branch: Option<String>,
    reused: bool,
}

pub(super) fn run(args: &[String]) -> i32 {
    if args.first().map(String::as_str) == Some("help")
        || args.iter().any(|arg| matches!(arg.as_str(), "-h" | "--help"))
    {
        println!("{USAGE}");
        return 0;
    }
    let Some(args) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    match stage(&args) {
        Ok(staged) => {
            let line = json!({"ok": true, "cwd": staged.cwd, "folder": staged.folder,
                              "repo": staged.repo, "head": staged.head,
                              "snapshot": staged.snapshot, "branch": staged.branch,
                              "reused": staged.reused});
            println!("{line}");
            0
        }
        Err(failure) => {
            println!(
                "{}",
                json!({"ok": false, "error": failure.error, "error_code": failure.code})
            );
            1
        }
    }
}

fn parse(args: &[String]) -> Option<Args> {
    let [kind, rest @ ..] = args else { return None };
    if kind != "ssh" {
        return None;
    }
    let (mut to, mut port, mut ssh, mut key, mut folder) = (None, None, None, None, None);
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--to" => to = Some(rest.next()?.clone()),
            "--port" => port = Some(rest.next()?.parse::<u16>().ok()?),
            "--ssh-binary" => ssh = Some(rest.next()?.clone()),
            "--key" => key = Some(rest.next()?.clone()),
            flag if flag.starts_with('-') => return None,
            path if folder.is_none() => folder = Some(PathBuf::from(path)),
            _ => return None,
        }
    }
    // A destination that reads as an option would reach ssh as one.
    let to = to.filter(|to| !to.is_empty() && !to.starts_with('-'))?;
    let key = name_part(&key?, MAX_KEY);
    let folder = folder.filter(|folder| folder.is_absolute())?;
    (!key.is_empty()).then_some(Args {
        to,
        port,
        ssh: ssh.unwrap_or_else(|| "ssh".into()),
        key,
        folder,
    })
}

/// `raw` as a file and ref name part: ASCII letters, digits, `.`, `_` and
/// `-`, no leading dot, at most `max` bytes.
fn name_part(raw: &str, max: usize) -> String {
    let kept: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(max)
        .collect();
    kept.trim_start_matches('.').to_owned()
}

fn stage(args: &Args) -> Result<Staged, Failed> {
    let local = Local::read(&args.folder)?;
    let ssh = Ssh { binary: &args.ssh, to: &args.to, port: args.port };
    let repo = prepare(&ssh, &local)?;
    push(&ssh, &local, &repo, &args.key)?;
    place(&ssh, &local, &repo, &args.key)
}

/// This Mac's working copy and its snapshot.
struct Local {
    root: PathBuf,
    /// `FOLDER` under the root, `/`-separated; empty at the root.
    sub: String,
    head: String,
    snapshot: String,
    branch: Option<String>,
    origin: Option<String>,
    /// The repository's folder name on the host.
    name: String,
}

impl Local {
    fn read(folder: &Path) -> Result<Self, Failed> {
        if !folder.is_dir() {
            return Err(failed("stage.no_folder", format!("{} is not a folder", folder.display())));
        }
        let top = git(folder, &["rev-parse", "--show-toplevel"], &[]).map_err(|_| {
            failed("stage.not_git", format!("{} is not in a git repository", folder.display()))
        })?;
        let root = PathBuf::from(top);
        let sub = folder
            .canonicalize()
            .ok()
            .zip(root.canonicalize().ok())
            .and_then(|(folder, root)| folder.strip_prefix(&root).ok().map(Path::to_path_buf))
            .map(|sub| sub.to_string_lossy().into_owned())
            .unwrap_or_default();
        let head = git(&root, &["rev-parse", "--verify", "HEAD^{commit}"], &[])
            .map_err(|_| failed("stage.no_commit", "the repository has no commit yet"))?;
        let branch = git(&root, &["symbolic-ref", "-q", "--short", "HEAD"], &[]).ok();
        let origin = git(&root, &["remote", "get-url", "origin"], &[]).ok();
        let base =
            root.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        let name = Some(name_part(&base, 64))
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "repo".into());
        let snapshot = snapshot(&root, &head)?;
        Ok(Self { root, sub, head, snapshot, branch, origin, name })
    }
}

/// A commit on `head` whose tree is the working copy as `git add -A` sees it,
/// built in a temporary index.
fn snapshot(root: &Path, head: &str) -> Result<String, Failed> {
    /// Removes the temporary index however the snapshot ends.
    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let scratch = Scratch(
        std::env::temp_dir().join(format!("cmux-stage-{}-{nanos}.index", std::process::id())),
    );
    let index = scratch.0.to_string_lossy().into_owned();
    let env = [("GIT_INDEX_FILE", index.as_str())];
    let snap = |e: String| failed("stage.failed", format!("snapshot of the working copy: {e}"));
    git(root, &["read-tree", head], &env).map_err(snap)?;
    git(root, &["add", "-A", "--", "."], &env).map_err(snap)?;
    let tree = git(root, &["write-tree"], &env).map_err(snap)?;
    // A transport commit nobody sees: the host resets its index to HEAD.
    let who = [
        ("GIT_AUTHOR_NAME", "cmux"),
        ("GIT_AUTHOR_EMAIL", "cmux@localhost"),
        ("GIT_COMMITTER_NAME", "cmux"),
        ("GIT_COMMITTER_EMAIL", "cmux@localhost"),
    ];
    git(root, &["commit-tree", &tree, "-p", head, "-m", "cmux move snapshot"], &who).map_err(snap)
}

/// `git -C dir args` with `env`: its trimmed stdout, or its stderr.
fn git(dir: &Path, args: &[&str], env: &[(&str, &str)]) -> Result<String, String> {
    let mut command = Command::new("git");
    command.arg("-C").arg(dir).args(args).stdin(Stdio::null());
    for (key, value) in env {
        command.env(key, value);
    }
    let output = command.output().map_err(|e| format!("git: {e}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_owned())
    }
}

struct Ssh<'a> {
    binary: &'a str,
    to: &'a str,
    port: Option<u16>,
}

impl Ssh<'_> {
    /// Runs `script` with `sh -s` on the host.
    fn script(&self, script: &str) -> Result<Output, Failed> {
        let mut command = Command::new(self.binary);
        command.arg("-T").args(SSH_OPTIONS);
        if let Some(port) = self.port {
            command.arg("-p").arg(port.to_string());
        }
        command.args(["--", self.to, "sh -s"]);
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let unreachable =
            |e: std::io::Error| failed("ssh_unreachable", format!("{}: {e}", self.binary));
        let mut child = command.spawn().map_err(unreachable)?;
        if let Some(mut stdin) = child.stdin.take() {
            // A host that closes early answers through its exit status.
            let _ = stdin.write_all(script.as_bytes());
        }
        let output = child.wait_with_output().map_err(unreachable)?;
        // ssh's own failure (no route, no auth, host key) is 255.
        if output.status.code() == Some(255) {
            let error = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            return Err(failed("ssh_unreachable", format!("ssh {}: {error}", self.to)));
        }
        Ok(output)
    }

    /// `ssh://` URL of the host's absolute `path`, for git.
    fn url(&self, path: &str) -> String {
        match self.port {
            Some(port) => format!("ssh://{}:{port}{path}", self.to),
            None => format!("ssh://{}{path}", self.to),
        }
    }
}

/// `value` as one POSIX shell word.
fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// The `key=value` lines a script printed.
fn fields(output: &Output) -> Vec<(String, String)> {
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.split_once('='))
        .map(|(key, value)| (key.to_owned(), value.to_owned()))
        .collect()
}

fn field<'a>(fields: &'a [(String, String)], key: &str) -> Option<&'a str> {
    fields.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
}

/// The host's repository for this working copy.
struct Repo {
    path: String,
    home: String,
}

const PREPARE: &str = r#"
command -v git >/dev/null 2>&1 || { echo "error=stage.no_git_remote"; exit 3; }
work="$HOME/work"; repo="$work/$NAME"
mkdir -p "$work" || exit 4
if [ ! -e "$repo" ]; then
  git init -q "$repo" || exit 4
  [ -z "$ORIGIN" ] || git -C "$repo" remote add origin "$ORIGIN" || exit 4
fi
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "error=stage.not_a_repository"; exit 5; }
printf 'home=%s\nrepo=%s\norigin=%s\n' "$HOME" "$repo" "$(git -C "$repo" remote get-url origin 2>/dev/null)"
"#;

fn prepare(ssh: &Ssh<'_>, local: &Local) -> Result<Repo, Failed> {
    let origin = local.origin.as_deref().unwrap_or("");
    let script = format!("NAME={}\nORIGIN={}\n{PREPARE}", quote(&local.name), quote(origin));
    let output = ssh.script(&script)?;
    let fields = fields(&output);
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    match field(&fields, "error") {
        Some("stage.no_git_remote") => {
            return Err(failed("stage.no_git_remote", format!("{} has no git", ssh.to)));
        }
        Some("stage.not_a_repository") => {
            return Err(failed(
                "stage.not_a_repository",
                format!("~/work/{} on {} is not a git repository", local.name, ssh.to),
            ));
        }
        _ => {}
    }
    let (Some(home), Some(path)) = (field(&fields, "home"), field(&fields, "repo")) else {
        return Err(failed(
            "stage.failed",
            format!("preparing ~/work/{} on {}: {stderr}", local.name, ssh.to),
        ));
    };
    if let Some(theirs) = field(&fields, "origin").filter(|theirs| !theirs.is_empty())
        && !origin.is_empty()
        && same_project(theirs) != same_project(origin)
    {
        return Err(failed(
            "stage.repo_mismatch",
            format!("{path} on {} is a clone of {theirs}, not {origin}", ssh.to),
        ));
    }
    Ok(Repo { path: path.to_owned(), home: home.to_owned() })
}

/// The `owner/name` an origin URL names, so ssh and https URLs of one
/// project compare equal.
fn same_project(url: &str) -> String {
    let path = url.trim().trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let parts: Vec<&str> = path.rsplit(['/', ':']).take(2).collect();
    parts.into_iter().rev().collect::<Vec<_>>().join("/").to_ascii_lowercase()
}

fn push(ssh: &Ssh<'_>, local: &Local, repo: &Repo, key: &str) -> Result<(), Failed> {
    let mut command = vec![quote(ssh.binary)];
    command.extend(SSH_OPTIONS.iter().map(|option| (*option).to_owned()));
    let ssh_command = command.join(" ");
    let url = ssh.url(&repo.path);
    let head = format!("+{}:refs/cmux/moves/{key}/head", local.head);
    let snap = format!("+{}:refs/cmux/moves/{key}/snap", local.snapshot);
    git(
        &local.root,
        &["push", "--quiet", "--no-verify", &url, &head, &snap],
        &[("GIT_SSH_COMMAND", &ssh_command)],
    )
    .map(drop)
    .map_err(|e| failed("stage.push_failed", format!("git push to {}: {e}", ssh.to)))
}

const PLACE: &str = r#"
placed_ref="refs/cmux/moves/$KEY/placed"
# The tree of the worktree at $1 as `git add -A` sees it.
tree_of() {
  idx="$(mktemp)" && rm -f "$idx" || return 1
  GIT_INDEX_FILE="$idx" git -C "$1" read-tree HEAD &&
    GIT_INDEX_FILE="$idx" git -C "$1" add -A -- . &&
    GIT_INDEX_FILE="$idx" git -C "$1" write-tree
  status=$?; rm -f "$idx"; return $status
}
reused=0; owned=""
if [ -e "$TREE" ]; then
  placed="$(git -C "$REPO" rev-parse -q --verify "$placed_ref^{commit}")" || placed=""
  now_head="$(git -C "$TREE" rev-parse -q --verify HEAD)" || now_head=""
  now_tree="$(tree_of "$TREE")" || now_tree=""
  if [ -z "$placed" ] || [ -z "$now_tree" ] ||
     [ "$now_head" != "$(git -C "$REPO" rev-parse "$placed^")" ] ||
     [ "$now_tree" != "$(git -C "$REPO" rev-parse "$placed^{tree}")" ]; then
    echo "error=stage.target_changed"; exit 6
  fi
  if [ "$HEAD" = "$now_head" ] && [ "$(git -C "$REPO" rev-parse "$SNAP^{tree}")" = "$now_tree" ]; then
    reused=1
  else
    # The branch this worktree made goes on with the rebuilt one.
    owned="$(git -C "$TREE" symbolic-ref -q --short HEAD)" || owned=""
    git -C "$REPO" worktree remove --force "$TREE" || exit 7
  fi
fi
if [ "$reused" = 0 ]; then
  git -C "$REPO" worktree prune
  mkdir -p "$(dirname "$TREE")" || exit 7
  git -C "$REPO" worktree add -q --detach "$TREE" "$HEAD" || exit 7
  git -C "$TREE" read-tree -u --reset "$SNAP" || exit 7
  git -C "$TREE" reset -q "$HEAD" || exit 7
  if [ -n "$BRANCH" ] && { [ "$owned" = "$BRANCH" ] || ! git -C "$REPO" show-ref -q --verify "refs/heads/$BRANCH"; }; then
    git -C "$TREE" checkout -q -B "$BRANCH" || exit 7
  fi
  git -C "$REPO" update-ref "$placed_ref" "$SNAP" || exit 7
fi
cwd="$TREE"
[ -z "$SUB" ] || [ ! -d "$TREE/$SUB" ] || cwd="$TREE/$SUB"
printf 'reused=%s\ncwd=%s\nbranch=%s\n' "$reused" "$cwd" "$(git -C "$TREE" symbolic-ref -q --short HEAD)"
"#;

fn place(ssh: &Ssh<'_>, local: &Local, repo: &Repo, key: &str) -> Result<Staged, Failed> {
    let tree = format!("{}/work/cmux-moves/{}-{key}", repo.home, local.name);
    let vars = [
        ("REPO", repo.path.as_str()),
        ("TREE", tree.as_str()),
        ("KEY", key),
        ("HEAD", local.head.as_str()),
        ("SNAP", local.snapshot.as_str()),
        ("BRANCH", local.branch.as_deref().unwrap_or("")),
        ("SUB", local.sub.as_str()),
    ];
    let mut script: String =
        vars.iter().map(|(name, value)| format!("{name}={}\n", quote(value))).collect();
    script.push_str(PLACE);
    let output = ssh.script(&script)?;
    let fields = fields(&output);
    if field(&fields, "error") == Some("stage.target_changed") {
        return Err(failed(
            "stage.target_changed",
            format!("{tree} on {} changed since it was staged; it was left as it is", ssh.to),
        ));
    }
    let (true, Some(cwd)) = (output.status.success(), field(&fields, "cwd")) else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(failed("stage.failed", format!("making {tree} on {}: {stderr}", ssh.to)));
    };
    Ok(Staged {
        cwd: cwd.to_owned(),
        folder: tree,
        repo: repo.path.clone(),
        head: local.head.clone(),
        snapshot: local.snapshot.clone(),
        branch: field(&fields, "branch").filter(|branch| !branch.is_empty()).map(str::to_owned),
        reused: field(&fields, "reused") == Some("1"),
    })
}
