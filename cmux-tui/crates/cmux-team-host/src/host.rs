//! Observing and changing the machine. The reconciler runs as root on the team VM (team-host role
//! of `cmux`). Every change goes through the shadow tools and `setfacl` with an argv (no shell),
//! or a direct `chown`/`chmod` syscall (exact mode bits; GNU `chmod` keeps setgid on directories).

use crate::acl::parse_getfacl;
use crate::desired::{Desired, Layout, compile};
use crate::directory::{Directory, Refusal, validate};
use crate::observed::{DirState, Observed, parse_group, parse_passwd};
use crate::plan::{Action, Plan, plan};
use std::io;
use std::path::{Path, PathBuf};

/// The machine as the reconciler sees it (replaced by a fake in unit tests).
pub trait System {
    fn read_to_string(&mut self, path: &Path) -> io::Result<String>;
    /// `None` when nothing exists at `path`. Never follows a symlink.
    fn dir_state(&mut self, path: &Path) -> io::Result<Option<DirState>>;
    /// Runs a program with these arguments; Err carries the exit status and stderr.
    fn run(&mut self, program: &str, args: &[String]) -> Result<(), String>;
    fn chown(&mut self, path: &Path, uid: u32, gid: u32) -> io::Result<()>;
    fn chmod(&mut self, path: &Path, mode: u32) -> io::Result<()>;
    fn mkdir(&mut self, path: &Path) -> io::Result<()>;
}

/// Where the account databases are (`/etc` on the VM).
#[derive(Clone, Debug)]
pub struct Accounts {
    pub passwd: PathBuf,
    pub group: PathBuf,
}

impl Default for Accounts {
    fn default() -> Self {
        Self { passwd: PathBuf::from("/etc/passwd"), group: PathBuf::from("/etc/group") }
    }
}

pub fn observe(
    sys: &mut dyn System,
    accounts: &Accounts,
    desired: &Desired,
) -> Result<Observed, String> {
    let users = parse_passwd(
        &sys.read_to_string(&accounts.passwd)
            .map_err(|e| format!("read {}: {e}", accounts.passwd.display()))?,
    )?;
    let groups = parse_group(
        &sys.read_to_string(&accounts.group)
            .map_err(|e| format!("read {}: {e}", accounts.group.display()))?,
    )?;
    let mut dirs = std::collections::BTreeMap::new();
    for d in &desired.dirs {
        let state =
            sys.dir_state(&d.path).map_err(|e| format!("stat {}: {e}", d.path.display()))?;
        dirs.insert(d.path.clone(), state);
    }
    Ok(Observed { users, groups, dirs })
}

fn path_arg(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

pub fn apply_one(sys: &mut dyn System, action: &Action) -> Result<(), String> {
    let s = |v: &str| v.to_string();
    match action {
        Action::DeleteUser { name } => sys.run("userdel", &[s(name)]),
        // 6 = the group does not exist (userdel may already have removed a private group).
        Action::DeleteGroup { name } => sys
            .run("groupdel", &[s(name)])
            .or_else(|e| if e.starts_with("exit 6") { Ok(()) } else { Err(e) }),
        Action::CreateGroup { name, gid } => {
            sys.run("groupadd", &[s("-g"), gid.to_string(), s(name)])
        }
        Action::CreateUser { name, uid, gid, home, shell } => sys.run(
            "useradd",
            &[
                s("-u"),
                uid.to_string(),
                s("-g"),
                gid.to_string(),
                s("-N"),
                s("-M"),
                s("-d"),
                path_arg(home),
                s("-s"),
                s(shell),
                s(name),
            ],
        ),
        Action::FixUser { name, gid, home, shell } => sys.run(
            "usermod",
            &[s("-g"), gid.to_string(), s("-d"), path_arg(home), s("-s"), s(shell), s(name)],
        ),
        Action::SetGroups { name, groups } => {
            sys.run("usermod", &[s("-G"), groups.join(","), s(name)])
        }
        Action::Mkdir { path } => {
            sys.mkdir(path).map_err(|e| format!("mkdir {}: {e}", path.display()))
        }
        Action::Chown { path, uid, gid } => {
            sys.chown(path, *uid, *gid).map_err(|e| format!("chown {}: {e}", path.display()))
        }
        Action::Chmod { path, mode } => {
            sys.chmod(path, *mode).map_err(|e| format!("chmod {}: {e}", path.display()))
        }
        Action::SetAcl { path, acl } => {
            sys.run("setfacl", &[s("-P"), s("--set"), acl.spec(), path_arg(path)])?;
            sys.run("setfacl", &[s("-P"), s("-d"), s("--set"), acl.spec(), path_arg(path)])
        }
        Action::ClearAcl { path } => sys.run("setfacl", &[s("-P"), s("-b"), path_arg(path)]),
    }
}

/// What one reconcile did.
#[derive(Clone, Debug, Default)]
pub struct Report {
    pub applied: Vec<Action>,
    pub errors: Vec<String>,
    pub refusals: Vec<Refusal>,
    /// The plan after the last pass; empty when the machine matches the directory.
    pub remaining: Plan,
}

/// Plans and applies until nothing is left (at most `passes` rounds: a deleted user's private
/// group, for example, disappears only after `userdel`). Refusals from the directory and from the
/// machine are reported; a failing action is reported and the rest still runs.
pub fn reconcile(
    sys: &mut dyn System,
    accounts: &Accounts,
    layout: &Layout,
    dir: &Directory,
) -> Report {
    let (valid, mut refusals) = validate(dir);
    let desired = compile(&valid, layout);
    let mut report = Report::default();
    for _ in 0..3 {
        let observed = match observe(sys, accounts, &desired) {
            Ok(o) => o,
            Err(e) => {
                report.errors.push(e);
                break;
            }
        };
        let p = plan(&desired, &observed);
        if p.actions.is_empty() {
            report.remaining = p;
            break;
        }
        for a in &p.actions {
            match apply_one(sys, a) {
                Ok(()) => report.applied.push(a.clone()),
                Err(e) => report.errors.push(e),
            }
        }
        report.remaining = p;
    }
    refusals.extend(report.remaining.refusals.iter().cloned());
    refusals.sort();
    refusals.dedup();
    report.refusals = refusals;
    report
}

/// The real machine (Linux, as root).
///
/// Known gap (before production): writers of a node directory can rename the `p/` directory in it
/// and put a symlink there. Observing refuses a symlink, and every change checks that no component
/// of its path is a symlink right before it runs, but a swap between that check and the syscall is
/// still possible. The fix is fd-relative changes (`openat` with `O_NOFOLLOW`, `fchownat`,
/// `fchmodat`) on a directory fd walked from the team root.
#[cfg(unix)]
pub struct HostSystem;

/// Refuses a path with a symlink in any component (the reconciler runs as root).
#[cfg(unix)]
fn no_symlink(path: &Path) -> io::Result<()> {
    let mut cur = PathBuf::new();
    for c in path.components() {
        cur.push(c);
        if std::fs::symlink_metadata(&cur).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(io::Error::other(format!("{} is a symlink; refused", cur.display())));
        }
    }
    Ok(())
}

#[cfg(unix)]
impl System for HostSystem {
    fn read_to_string(&mut self, path: &Path) -> io::Result<String> {
        std::fs::read_to_string(path)
    }

    fn dir_state(&mut self, path: &Path) -> io::Result<Option<DirState>> {
        use std::os::unix::fs::MetadataExt;
        let meta = match std::fs::symlink_metadata(path) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e),
        };
        if !meta.is_dir() {
            return Ok(Some(DirState {
                is_dir: false,
                uid: meta.uid(),
                gid: meta.gid(),
                mode: meta.mode() & 0o7777,
                acl: Default::default(),
            }));
        }
        let out = std::process::Command::new("getfacl")
            .args(["-n", "-p", "--omit-header"])
            .arg(path)
            .output()?;
        if !out.status.success() {
            return Err(io::Error::other(format!(
                "getfacl {}: {}",
                path.display(),
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        let acl = parse_getfacl(&String::from_utf8_lossy(&out.stdout)).map_err(io::Error::other)?;
        Ok(Some(DirState {
            is_dir: true,
            uid: meta.uid(),
            gid: meta.gid(),
            mode: meta.mode() & 0o7777,
            acl,
        }))
    }

    fn run(&mut self, program: &str, args: &[String]) -> Result<(), String> {
        if program == "setfacl"
            && let Some(path) = args.last()
        {
            no_symlink(Path::new(path)).map_err(|e| e.to_string())?;
        }
        let out = std::process::Command::new(program)
            .args(args)
            .output()
            .map_err(|e| format!("{program}: {e}"))?;
        if out.status.success() {
            return Ok(());
        }
        Err(format!(
            "exit {} from {program} {}: {}",
            out.status.code().unwrap_or(-1),
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }

    fn chown(&mut self, path: &Path, uid: u32, gid: u32) -> io::Result<()> {
        no_symlink(path)?;
        std::os::unix::fs::lchown(path, Some(uid), Some(gid))
    }

    fn chmod(&mut self, path: &Path, mode: u32) -> io::Result<()> {
        use std::os::unix::fs::PermissionsExt;
        no_symlink(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
    }

    fn mkdir(&mut self, path: &Path) -> io::Result<()> {
        no_symlink(path)?;
        std::fs::create_dir(path)
    }
}
