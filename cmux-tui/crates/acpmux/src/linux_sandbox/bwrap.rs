//! Bubblewrap mount/namespace plan. Not wired to remote spawns until G2.
//! This layer alone is insufficient: the seccomp supervisor and network
//! proxy must also be installed before a remote command may run.
#![allow(dead_code)] // Staged API: G1/G2 supply the production callers.

use std::fmt;
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;
use wait_timeout::ChildExt;

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
pub(crate) const LINUX_READ_DENIES: &[&str] = &[
    ".local/share/keyrings",
    ".password-store",
    ".mozilla",
    ".config/google-chrome",
    ".config/chromium",
    ".config/BraveSoftware",
    ".pki",
    ".claude/.credentials.json",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Mask {
    Directory(PathBuf),
    /// A read-only /dev/null bind. Bubblewrap's nodev mounts can make
    /// reads fail with EACCES instead of returning EOF; either hides the file.
    File(PathBuf),
}

/// Select existing absolute read-denied paths plus the Linux HOME additions.
/// Resolve symlinks so both the symlink and its canonical target are masked.
/// Only ENOENT is omitted; other metadata failures retain a file mask so
/// bwrap either conceals the path or refuses setup. Iteration ends after
/// the supplied denies and the fixed Linux additions have been visited.
pub(crate) fn masks(home: &Path, read_denies: &[PathBuf]) -> Vec<Mask> {
    read_denies
        .iter()
        .cloned()
        .chain(LINUX_READ_DENIES.iter().map(|p| home.join(p)))
        .filter_map(|path| {
            let path = std::fs::canonicalize(&path).unwrap_or(path);
            match std::fs::metadata(&path) {
                Ok(meta) if meta.is_dir() => Some(Mask::Directory(path)),
                Err(e) if e.kind() == io::ErrorKind::NotFound => None,
                _ => Some(Mask::File(path)),
            }
        })
        .collect()
}

/// Pure argv construction, including the command prefix after `--`.
/// The loops end after four writable roots and the supplied masks.
pub(crate) fn bwrap_args(paths: &Paths, masks: &[Mask], cmd_prefix: &[String]) -> Vec<String> {
    let mut out: Vec<String> = [
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
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    for path in [&paths.cwd, &paths.tmp, &paths.claude_tmp_project, &paths.claude_project] {
        let path = path_arg(path);
        out.extend(["--bind".into(), path.clone(), path]);
    }
    let memory = path_arg(&paths.claude_project.join("memory"));
    out.extend(["--ro-bind".into(), memory.clone(), memory]);
    for mask in masks {
        match mask {
            Mask::Directory(path) => {
                let path = path_arg(path);
                out.extend(["--tmpfs".into(), path.clone(), "--remount-ro".into(), path]);
            }
            Mask::File(path) => {
                out.extend(["--ro-bind".into(), "/dev/null".into(), path_arg(path)]);
            }
        }
    }
    out.extend([
        "--chdir".into(),
        path_arg(&paths.cwd),
        "--cap-drop".into(),
        "ALL".into(),
        "--".into(),
    ]);
    out.extend_from_slice(cmd_prefix);
    out
}

/// Fail closed on invalid caller data; lossy conversion could mask a
/// different path or grant writes to a different directory.
fn path_arg(path: &Path) -> String {
    assert!(path.is_absolute(), "sandbox paths must be absolute");
    assert!(
        !path.components().any(|c| c == std::path::Component::ParentDir),
        "sandbox paths must not contain .."
    );
    path.to_str().expect("sandbox paths must be UTF-8").to_owned()
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
        f.write_str(match self {
            Self::NotInstalled => "bwrap not installed (Debian/Ubuntu: apt install bubblewrap)",
            Self::TooOld => "bwrap older than 0.8 (missing --disable-userns)",
            Self::UserNamespacesRestricted => "unprivileged user namespaces are restricted (kernel.apparmor_restrict_unprivileged_userns=1) and /usr/bin/bwrap has no AppArmor profile; install it: Ubuntu's apparmor package ships /etc/apparmor.d/bwrap-userns-restrict",
            Self::Other(stderr) => stderr,
        })
    }
}

/// Classify a completed probe; `None` means the child died by signal.
fn classify(status: Option<i32>, stderr: &str) -> Result<(), Unavailable> {
    if status == Some(0) {
        return Ok(());
    }
    let stderr = stderr.trim();
    let lower = stderr.to_ascii_lowercase();
    if lower.contains("--disable-userns")
        && (lower.contains("unknown option") || lower.contains("unrecognized option"))
    {
        return Err(Unavailable::TooOld);
    }
    if lower.contains("no permissions to create new namespace")
        || ((lower.contains("setting up uid map") || lower.contains("creating new namespace"))
            && (lower.contains("permission denied") || lower.contains("operation not permitted")))
    {
        return Err(Unavailable::UserNamespacesRestricted);
    }
    Err(Unavailable::Other(if stderr.is_empty() {
        match status {
            Some(code) => format!("bwrap probe failed (exit status {code}, no stderr)"),
            None => "bwrap probe terminated by signal (no stderr)".into(),
        }
    } else {
        stderr.to_owned()
    }))
}

/// Stop after the probe exits or 10 seconds elapse; kill and reap on timeout
/// or wait failure. Stderr reads end at EOF, WouldBlock, or 16 KiB: even an
/// inherited stderr writer cannot hold the probe open after its child exits.
pub(crate) fn probe(bwrap: &Path) -> Result<(), Unavailable> {
    let mut child = Command::new(bwrap)
        .args([
            "--unshare-user",
            "--unshare-net",
            "--disable-userns",
            "--ro-bind",
            "/",
            "/",
            "true",
        ])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            if e.kind() == io::ErrorKind::NotFound {
                Unavailable::NotInstalled
            } else {
                Unavailable::Other(format!("bwrap probe did not start: {e}"))
            }
        })?;
    let status = match child.wait_timeout(Duration::from_secs(10)) {
        Ok(Some(status)) => status,
        result => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Unavailable::Other(match result {
                Err(e) => format!("bwrap probe wait failed: {e}"),
                _ => "bwrap probe did not finish in 10 s".into(),
            }));
        }
    };
    let stderr = child.stderr.take().expect("stderr was piped");
    // SAFETY: stderr owns a live pipe fd. F_SETFL changes only its status flags.
    if unsafe { libc::fcntl(stderr.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } == -1 {
        return Err(Unavailable::Other(format!("bwrap stderr: {}", io::Error::last_os_error())));
    }
    let mut bytes = Vec::new();
    if let Err(e) = stderr.take(16 * 1024).read_to_end(&mut bytes)
        && e.kind() != io::ErrorKind::WouldBlock
    {
        return Err(Unavailable::Other(format!("bwrap stderr: {e}")));
    }
    classify(status.code(), &String::from_utf8_lossy(&bytes))
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

    #[test]
    fn masks_resolve_symlinks_and_do_not_omit_inspection_errors() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        let home = fixture.0.join("home");
        fs::create_dir(&home).unwrap();
        let directory = fixture.0.join("secret-directory");
        let file = fixture.0.join("secret-file");
        fs::create_dir(&directory).unwrap();
        fs::write(&file, "synthetic credential").unwrap();
        symlink(&directory, home.join(".ssh")).unwrap();
        symlink(&file, home.join(".netrc")).unwrap();
        symlink("loop", home.join("loop")).unwrap();
        symlink("absent", home.join("dangling")).unwrap();
        assert_eq!(
            masks(
                &home,
                &[home.join(".ssh"), home.join(".netrc"), home.join("loop"), home.join("dangling"),]
            ),
            vec![Mask::Directory(directory), Mask::File(file), Mask::File(home.join("loop"))],
        );
    }

    #[test]
    #[should_panic(expected = "sandbox paths must be UTF-8")]
    fn argv_refuses_lossy_path_conversion() {
        use std::os::unix::ffi::OsStringExt;
        let fixture = Fixture::new();
        let mut p = fixture.paths();
        p.cwd = std::ffi::OsString::from_vec(b"/invalid-\xff".to_vec()).into();
        let _ = bwrap_args(&p, &[], &strings(&["true"]));
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
            classify(Some(1), "bwrap: unrecognized option '--disable-userns'"),
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
    /// finite /proc snapshots and network tables; no background jobs are made.
    #[tokio::test]
    async fn real_bwrap_isolates_mounts_processes_and_network() {
        let bwrap = Path::new("/usr/bin/bwrap");
        if let Err(reason) = probe(bwrap) {
            assert!(
                std::env::var_os("ACPMUX_REQUIRE_BWRAP").is_none(),
                "real bwrap required but probe failed: {reason}"
            );
            eprintln!("skipped: {reason}");
            return;
        }
        eprintln!("running: real bwrap isolation test ({})", bwrap.display());
        let fixture = Fixture::new();
        let p = fixture.create_paths();
        let outside = fixture.0.join("outside");
        fs::write(&outside, "unchanged").unwrap();
        let secret = p.home.join(".netrc");
        const FILE_MARKER: &str = "acpmux-file-secret-marker";
        const DIRECTORY_MARKER: &str = ".acpmux-directory-secret-marker";
        fs::write(&secret, FILE_MARKER).unwrap();
        let secrets = p.home.join(".ssh");
        fs::create_dir(&secrets).unwrap();
        fs::write(secrets.join(DIRECTORY_MARKER), DIRECTORY_MARKER).unwrap();
        let memory = p.claude_project.join("memory/keep");
        fs::write(&memory, "unchanged").unwrap();
        let host_pid_ns = fs::read_link("/proc/self/ns/pid").unwrap();
        let host_net_ns = fs::read_link("/proc/self/ns/net").unwrap();
        let script = r#"
set -eu
outside=$1; secret=$2; secrets=$3; tmp=$4; scratch=$5; project=$6; host_pid_ns=$7; host_net_ns=$8
file_marker=$9; directory_marker=${10}
fail() { code=$1; shift; printf 'check %s: %s\n' "$code" "$*" >&2; exit "$code"; }
# A nodev /dev/null mask can deny the open instead of returning EOF.
# Capture stdout even on failure, so partial disclosure cannot pass.
check_hidden_read() {
    content=$(cat -- "$1" 2>/dev/null) || :
    case "$content" in *"$2"*) fail "$3" "masked read path=$1 exposed marker; content=<$content>";; esac
    case "$content" in '') ;; *) fail "$4" "masked read path=$1 returned content=<$content>";; esac
}
if (printf changed > "$outside") 2>/dev/null; then
    fail 10 "outside write succeeded: path=$outside"
fi
printf inside > ./inside || fail 11 "cwd write failed: status=$? path=./inside"
printf temp > "$tmp/inside" || fail 12 "temp write failed: status=$? path=$tmp/inside"
printf scratch > "$scratch/inside" || fail 13 "scratch write failed: status=$? path=$scratch/inside"
printf transcript > "$project/inside" || fail 14 "transcript write failed: status=$? path=$project/inside"
if (printf changed > "$project/memory/keep") 2>/dev/null; then
    fail 15 "memory write succeeded: path=$project/memory/keep"
fi
check_hidden_read "$secret" "$file_marker" 16 17
check_hidden_read "$secrets/$directory_marker" "$directory_marker" 18 19
listing=$(ls -A -- "$secrets" 2>/dev/null) || :
case "$listing" in *"$directory_marker"*) fail 20 "masked directory exposed marker: listing=<$listing>";; esac
case "$listing" in '') ;; *) fail 21 "masked directory returned entries: listing=<$listing>";; esac
if [ -e "$secrets/$directory_marker" ]; then
    fail 22 "masked entry exists: path=$secrets/$directory_marker listing=<$listing>"
fi
if (printf changed > "$secrets/new") 2>/dev/null; then
    fail 23 "masked directory write succeeded: path=$secrets/new"
fi
self_pid_ns=$(readlink /proc/self/ns/pid 2>&1) || fail 24 "self PID namespace readlink failed: status=$? output=<$self_pid_ns>"
case "$self_pid_ns" in '') fail 25 "self PID namespace empty: observed=<$self_pid_ns>";; esac
if [ "$self_pid_ns" = "$host_pid_ns" ]; then
    fail 26 "PID namespace not isolated: sandbox=<$self_pid_ns> host=<$host_pid_ns>"
fi
init_pid_ns=$(readlink /proc/1/ns/pid 2>&1) || fail 27 "PID 1 namespace readlink failed: status=$? output=<$init_pid_ns>"
case "$init_pid_ns" in '') fail 28 "PID 1 namespace empty: observed=<$init_pid_ns>";; esac
if [ "$init_pid_ns" != "$self_pid_ns" ]; then
    fail 29 "PID namespace mismatch: PID1=<$init_pid_ns> self=<$self_pid_ns>"
fi
count=0; entries=
for entry in /proc/[0-9]*; do count=$((count + 1)); entries="$entries $entry"; done
if [ "$count" -gt 4 ]; then
    fail 30 "too many visible processes: count=$count entries=<$entries>"
fi

# The host's sysfs mount describes its network namespace. Use only the
# per-reader /proc view here; loaded modules may create fallback devices.
self_net_ns=$(readlink /proc/self/ns/net 2>&1) || fail 31 "network namespace readlink failed: status=$? output=<$self_net_ns>"
case "$self_net_ns" in '') fail 32 "network namespace empty: observed=<$self_net_ns>";; esac
if [ "$self_net_ns" = "$host_net_ns" ]; then
    fail 33 "network namespace not isolated: sandbox=<$self_net_ns> host=<$host_net_ns>"
fi
net_data=$(cat /proc/net/dev 2>&1) || fail 34 "network interface table read failed: status=$? output=<$net_data>"
bad_iface=$(printf '%s\n' "$net_data" | awk -F: '/:/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 !~ /^(lo|tunl0|gre0|gretap0|erspan0|ip_vti0|ip6_vti0|sit0|ip6tnl0|ip6gre0)$/) print $0 }') || fail 35 "interface inspection failed: status=$? data=<$net_data>"
case "$bad_iface" in '') ;; *) fail 36 "unexpected interface: observed=<$bad_iface> all=<$net_data>";; esac

ipv6_data=$(cat /proc/net/if_inet6 2>&1) || fail 37 "IPv6 address table read failed: status=$? output=<$ipv6_data>"
bad_ipv6=$(printf '%s\n' "$ipv6_data" | awk 'NF && (NF != 6 || $1 != "00000000000000000000000000000001") { print $0 }') || fail 38 "IPv6 address inspection failed: status=$? data=<$ipv6_data>"
case "$bad_ipv6" in '') ;; *) fail 39 "non-loopback IPv6 address: observed=<$bad_ipv6> all=<$ipv6_data>";; esac

fib_data=$(cat /proc/net/fib_trie 2>&1) || fail 40 "IPv4 address table read failed: status=$? output=<$fib_data>"
# Each leaf address precedes its /prefix scope/type line. Only LOCAL
# entries are assigned addresses; UNICAST/BROADCAST entries are not.
bad_ipv4=$(printf '%s\n' "$fib_data" | awk '/\|--/ { address=$2 } $NF == "LOCAL" && address !~ /^127\.[0-9]+\.[0-9]+\.[0-9]+$/ { print "address=<" address "> " $0 }') || fail 41 "IPv4 LOCAL address inspection failed: status=$? data=<$fib_data>"
case "$bad_ipv4" in '') ;; *) fail 42 "non-loopback IPv4 LOCAL address: observed=<$bad_ipv4> all=<$fib_data>";; esac

route_data=$(cat /proc/net/route 2>&1) || fail 43 "IPv4 route table read failed: status=$? output=<$route_data>"
bad_route=$(printf '%s\n' "$route_data" | awk 'NR > 1 && NF { print $0 }') || fail 44 "IPv4 route inspection failed: status=$? data=<$route_data>"
case "$bad_route" in '') ;; *) fail 45 "unexpected IPv4 route: observed=<$bad_route> all=<$route_data>";; esac
ipv6_route_data=$(cat /proc/net/ipv6_route 2>&1) || fail 46 "IPv6 route table read failed: status=$? output=<$ipv6_route_data>"
bad_ipv6_route=$(printf '%s\n' "$ipv6_route_data" | awk 'NF && (NF != 10 || $10 != "lo") { print $0 }') || fail 47 "IPv6 route inspection failed: status=$? data=<$ipv6_route_data>"
case "$bad_ipv6_route" in '') ;; *) fail 48 "non-loopback IPv6 route: observed=<$bad_ipv6_route> all=<$ipv6_route_data>";; esac
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
                &host_net_ns,
            ]
            .into_iter()
            .map(|path| path.to_str().unwrap().to_owned()),
        );
        command.extend([FILE_MARKER.to_owned(), DIRECTORY_MARKER.to_owned()]);
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
        eprintln!("passed: real bwrap mount, PID, and network isolation");
    }
}
