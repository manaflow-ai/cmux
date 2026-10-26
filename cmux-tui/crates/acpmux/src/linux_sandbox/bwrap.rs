//! Bubblewrap mount/namespace plan. Not wired to remote spawns until G2.
//! This layer alone is insufficient: the seccomp supervisor and network
//! proxy must also be installed before a remote command may run.
#![allow(dead_code)] // Staged API: G1/G2 supply the production callers.

use std::fmt;
use std::path::{Path, PathBuf};

/// Canonical absolute UTF-8 paths, validated and created by the caller.
/// `claude_project/memory` must already exist, too.
#[derive(Debug, Clone)]
pub(crate) struct Paths {
    pub(crate) cwd: PathBuf,
    pub(crate) tmp: PathBuf,
    pub(crate) home: PathBuf,
    pub(crate) claude_tmp_project: PathBuf,
    pub(crate) claude_project: PathBuf,
}

/// HOME-relative Linux additions; the shared deny list comes from Seatbelt.
pub(crate) const LINUX_READ_DENIES: &[&str] = &[];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Mask {
    Directory(PathBuf),
    File(PathBuf),
}

/// Select existing absolute read-denied paths plus the Linux HOME additions.
pub(crate) fn masks(_home: &Path, _read_denies: &[PathBuf]) -> Vec<Mask> {
    Vec::new() // Red-first stub.
}

/// Pure argv construction, including the command prefix after `--`.
pub(crate) fn bwrap_args(_paths: &Paths, _masks: &[Mask], _cmd_prefix: &[String]) -> Vec<String> {
    Vec::new() // Red-first stub.
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Unavailable {
    NotInstalled,
    TooOld,
    UserNamespacesRestricted,
    Other(String),
}

impl fmt::Display for Unavailable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "bwrap probe not implemented") // Red-first stub.
    }
}

/// Classify a completed probe; `None` means the child died by signal.
fn classify(_status: Option<i32>, _stderr: &str) -> Result<(), Unavailable> {
    Err(Unavailable::Other("red-first stub".into()))
}

pub(crate) fn probe(_bwrap: &Path) -> Result<(), Unavailable> {
    Err(Unavailable::Other("red-first stub".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let root =
                std::env::temp_dir().join(format!("acpmux-bwrap-test-{}", uuid::Uuid::now_v7()));
            fs::create_dir(&root).unwrap();
            Self(fs::canonicalize(root).unwrap())
        }

        fn paths(&self) -> Paths {
            Paths {
                cwd: self.0.join("home/session with spaces"),
                tmp: self.0.join("spawn-tmp"),
                home: self.0.join("home"),
                claude_tmp_project: self.0.join("claude-scratch/session"),
                claude_project: self.0.join("home/.claude/projects/session"),
            }
        }

        /// Stops after creating the fixed four writable roots and memory.
        fn create_paths(&self) -> Paths {
            let p = self.paths();
            for dir in [&p.cwd, &p.tmp, &p.claude_tmp_project, &p.claude_project] {
                fs::create_dir_all(dir).unwrap();
            }
            fs::create_dir(p.claude_project.join("memory")).unwrap();
            p
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn argv_exact_mount_order_and_only_four_writable_host_binds() {
        // None of these paths exists: argv construction must be pure.
        let p = Paths {
            cwd: "/home/person/session with spaces".into(),
            tmp: "/tmp/acpmux-spawn".into(),
            home: "/home/person".into(),
            claude_tmp_project: "/tmp/claude-1000/session".into(),
            claude_project: "/home/person/.claude/projects/session".into(),
        };
        let selected = [Mask::Directory(p.home.join(".ssh")), Mask::File(p.home.join(".netrc"))];
        let command = strings(&["/usr/bin/acpmux", "__remote-sandbox-init", "--", "a b", "--bind"]);
        let args = bwrap_args(&p, &selected, &command);
        let mut expected = strings(&[
            "--new-session",
            "--die-with-parent",
            "--unshare-user",
            "--unshare-pid",
            "--unshare-ipc",
            "--unshare-net",
            "--unshare-uts",
            "--unshare-cgroup-try",
            "--disable-userns",
            "--ro-bind",
            "/",
            "/",
            "--dev",
            "/dev",
            "--proc",
            "/proc",
            "--bind",
            "/home/person/session with spaces",
            "/home/person/session with spaces",
            "--bind",
            "/tmp/acpmux-spawn",
            "/tmp/acpmux-spawn",
            "--bind",
            "/tmp/claude-1000/session",
            "/tmp/claude-1000/session",
            "--bind",
            "/home/person/.claude/projects/session",
            "/home/person/.claude/projects/session",
            "--ro-bind",
            "/home/person/.claude/projects/session/memory",
            "/home/person/.claude/projects/session/memory",
            "--tmpfs",
            "/home/person/.ssh",
            "--remount-ro",
            "/home/person/.ssh",
            "--ro-bind",
            "/dev/null",
            "/home/person/.netrc",
            "--chdir",
            "/home/person/session with spaces",
            "--cap-drop",
            "ALL",
            "--",
        ]);
        let options = args.iter().take_while(|s| s.as_str() != "--").collect::<Vec<_>>();
        assert_eq!(options.iter().filter(|s| s.as_str() == "--bind").count(), 4);
        expected.extend(command);
        assert_eq!(args, expected);
    }

    #[test]
    fn masks_only_existing_paths_and_preserves_file_directory_kind() {
        let fixture = Fixture::new();
        let home = fixture.0.join("home");
        fs::create_dir_all(home.join(".ssh")).unwrap();
        fs::write(home.join(".netrc"), "synthetic credential").unwrap();
        let denied = [home.join(".ssh"), home.join(".netrc"), home.join("absent")];
        assert_eq!(
            masks(&home, &denied),
            vec![Mask::Directory(home.join(".ssh")), Mask::File(home.join(".netrc"))],
        );
        assert!(masks(&fixture.0.join("missing-home"), &[]).is_empty());
    }

    /// Stops after the fixed Linux additions have each been created.
    #[test]
    fn linux_secret_masks_are_home_relative_and_added_to_shared_denies() {
        let fixture = Fixture::new();
        let home = fixture.0.join("home");
        let directories = [
            ".local/share/keyrings",
            ".password-store",
            ".mozilla",
            ".config/google-chrome",
            ".config/chromium",
            ".config/BraveSoftware",
            ".pki",
        ];
        let mut expected = Vec::new();
        for dir in directories {
            fs::create_dir_all(home.join(dir)).unwrap();
            expected.push(Mask::Directory(home.join(dir)));
        }
        fs::create_dir(home.join(".claude")).unwrap();
        fs::write(home.join(".claude/.credentials.json"), "synthetic login").unwrap();
        expected.push(Mask::File(home.join(".claude/.credentials.json")));
        let mut names = directories.to_vec();
        names.push(".claude/.credentials.json");
        assert_eq!(LINUX_READ_DENIES, names);
        assert_eq!(masks(&home, &[]), expected);
    }

    /// The canned-case loop stops at the end of this fixed table.
    #[test]
    fn probe_classification_is_pure_and_fail_closed() {
        assert_eq!(classify(Some(0), ""), Ok(()));
        assert_eq!(classify(Some(0), "a harmless warning"), Ok(()));
        for stderr in [
            "bwrap: setting up uid map: Permission denied",
            "bwrap: No permissions to create new namespace",
            "bwrap: Creating new namespace failed: Operation not permitted",
        ] {
            assert_eq!(classify(Some(1), stderr), Err(Unavailable::UserNamespacesRestricted));
        }
        assert_eq!(
            classify(Some(1), "bwrap: Unknown option --disable-userns"),
            Err(Unavailable::TooOld),
        );
        assert_eq!(
            classify(Some(1), "bwrap: Unknown option --unrelated"),
            Err(Unavailable::Other("bwrap: Unknown option --unrelated".into())),
        );
        assert_eq!(
            classify(Some(1), "bwrap: Can't mount /: Permission denied\n"),
            Err(Unavailable::Other("bwrap: Can't mount /: Permission denied".into())),
        );
        assert!(matches!(classify(Some(1), ""), Err(Unavailable::Other(_))));
        assert!(matches!(classify(None, ""), Err(Unavailable::Other(_))));
    }

    #[test]
    fn refusal_messages_name_the_remedy() {
        assert_eq!(
            Unavailable::NotInstalled.to_string(),
            "bwrap not installed (Debian/Ubuntu: apt install bubblewrap)"
        );
        assert_eq!(
            Unavailable::TooOld.to_string(),
            "bwrap older than 0.8 (missing --disable-userns)"
        );
        assert_eq!(
            Unavailable::UserNamespacesRestricted.to_string(),
            "unprivileged user namespaces are restricted (kernel.apparmor_restrict_unprivileged_userns=1) and /usr/bin/bwrap has no AppArmor profile; install it: Ubuntu's apparmor package ships /etc/apparmor.d/bwrap-userns-restrict"
        );
        assert_eq!(Unavailable::Other("diagnostic".into()).to_string(), "diagnostic");
    }

    #[test]
    fn missing_probe_executable_is_not_installed() {
        let fixture = Fixture::new();
        assert_eq!(probe(&fixture.0.join("absent-bwrap")), Err(Unavailable::NotInstalled));
    }

    /// The child is killed on the 20-second deadline. Shell loops exhaust
    /// finite /proc and /proc/net/dev snapshots; no background jobs are made.
    #[tokio::test]
    async fn real_bwrap_isolates_mounts_processes_and_network() {
        let bwrap = Path::new("/usr/bin/bwrap");
        if let Err(reason) = probe(bwrap) {
            eprintln!("skipped: {reason}");
            return;
        }
        let fixture = Fixture::new();
        let p = fixture.create_paths();
        let outside = fixture.0.join("outside");
        fs::write(&outside, "unchanged").unwrap();
        let secret = p.home.join(".netrc");
        fs::write(&secret, "synthetic credential").unwrap();
        let secrets = p.home.join(".ssh");
        fs::create_dir(&secrets).unwrap();
        fs::write(secrets.join("key"), "synthetic key").unwrap();
        let memory = p.claude_project.join("memory/keep");
        fs::write(&memory, "unchanged").unwrap();
        let host_pid_ns = fs::read_link("/proc/self/ns/pid").unwrap();
        let script = r#"
set -eu
outside=$1; secret=$2; secrets=$3; tmp=$4; scratch=$5; project=$6; host_pid_ns=$7
if (printf changed > "$outside") 2>/dev/null; then exit 10; fi
printf inside > ./inside
printf temp > "$tmp/inside"
printf scratch > "$scratch/inside"
printf transcript > "$project/inside"
if (printf changed > "$project/memory/keep") 2>/dev/null; then exit 11; fi
test "$(cat "$secret")" = ""
test ! -e "$secrets/key"
if (printf changed > "$secrets/new") 2>/dev/null; then exit 12; fi
test "$(readlink /proc/self/ns/pid)" != "$host_pid_ns"
test "$(readlink /proc/1/ns/pid)" = "$(readlink /proc/self/ns/pid)"
count=0
for entry in /proc/[0-9]*; do count=$((count + 1)); done
test "$count" -le 4
while IFS= read -r line; do
    case "$line" in *:*) iface=${line%%:*}; test "$(printf '%s' "$iface" | tr -d ' ')" = lo;; esac
done < /proc/net/dev
"#;
        let mut command = strings(&["/bin/sh", "-c", script, "acpmux-bwrap-test"]);
        command.extend(
            [
                &outside,
                &secret,
                &secrets,
                &p.tmp,
                &p.claude_tmp_project,
                &p.claude_project,
                &host_pid_ns,
            ]
            .into_iter()
            .map(|path| path.to_str().unwrap().to_owned()),
        );
        let args = bwrap_args(&p, &masks(&p.home, &[secrets, secret]), &command);
        let mut child = tokio::process::Command::new(bwrap);
        child
            .args(args)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true);
        let output = tokio::time::timeout(std::time::Duration::from_secs(20), child.output())
            .await
            .expect("bwrap test exceeded 20 seconds")
            .unwrap();
        assert!(
            output.status.success(),
            "status {}; stderr: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(fs::read_to_string(outside).unwrap(), "unchanged");
        assert_eq!(fs::read_to_string(memory).unwrap(), "unchanged");
        assert_eq!(fs::read_to_string(p.cwd.join("inside")).unwrap(), "inside");
    }
}
