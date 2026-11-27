//! The real pod runtime: a systemd slice per pod, processes in bubblewrap.
//!
//! Every command is an argv built here and handed to a [`CommandRunner`], which
//! runs it on the pod's host. On a pool VM the runner is local; from the
//! platform it is the host's machine link (`acpmux machine exec`), so this file
//! holds the whole host-side contract and its tests pin the exact commands.

use async_trait::async_trait;
use cmux_tui_machine_protocol::{ExecOutput, ExecRequest};

use crate::{PodPath, PodRuntime, PodSpec};

/// Runs one argv on a host, with stdin, and returns its output.
#[async_trait]
pub trait CommandRunner: Send + Sync {
    async fn run(&self, host: &str, argv: &[String], stdin: &[u8]) -> Result<ExecOutput, String>;
}

/// Runs commands on this machine: the runner a pool VM's own agent uses.
pub struct LocalRunner {
    /// The one host name this runner answers for.
    pub host: String,
}

#[async_trait]
impl CommandRunner for LocalRunner {
    async fn run(&self, host: &str, argv: &[String], stdin: &[u8]) -> Result<ExecOutput, String> {
        use crate::slots::HostRunner as _;
        if host != self.host {
            return Err(format!("{host} is not this machine ({})", self.host));
        }
        // One process path for both drivers: `ProcessRunner` owns each child
        // (`cmux_process`), on the blocking pool so the runtime keeps running.
        let (argv, stdin) = (argv.to_vec(), stdin.to_vec());
        let out =
            tokio::task::spawn_blocking(move || crate::slots::ProcessRunner.run(&argv, &stdin))
                .await
                .map_err(|e| format!("runner task: {e}"))??;
        Ok(ExecOutput { exit_code: out.code, stdout: out.stdout, stderr: out.stderr })
    }
}

/// Pods as systemd slices of the pool user's manager (`systemctl --user`).
pub struct SystemdPodRuntime<X> {
    runner: X,
    /// Directory on each host that holds the pod roots, e.g. `/home/cmux/pods`.
    pods_dir: String,
}

impl<X: CommandRunner> SystemdPodRuntime<X> {
    pub fn new(runner: X, pods_dir: impl Into<String>) -> Self {
        Self { runner, pods_dir: pods_dir.into().trim_end_matches('/').to_owned() }
    }

    /// The pod's root directory on its host.
    pub fn root(&self, pod: &PodSpec) -> String {
        format!("{}/{}", self.pods_dir, pod.id)
    }

    /// `-` nests slices in systemd, so the unit token uses `_`.
    pub fn slice(pod: &PodSpec) -> String {
        format!("cmux_pod_{}.slice", pod.id.replace('-', "_"))
    }

    pub fn start_argv(&self, pod: &PodSpec) -> Vec<Vec<String>> {
        let token = pod.id.replace('-', "_");
        vec![
            argv(&["mkdir", "-p", "--", &self.root(pod)]),
            // A holder keeps the slice alive between execs, so freeze has a target.
            argv(&[
                "systemd-run",
                "--user",
                "--quiet",
                "--collect",
                &format!("--unit=cmux_pod_{token}_hold"),
                &format!("--slice={}", Self::slice(pod)),
                "--",
                "sleep",
                "infinity",
            ]),
            // The pod's size, on the slice so every exec shares it.
            argv(&[
                "systemctl",
                "--user",
                "set-property",
                "--runtime",
                &Self::slice(pod),
                &format!("CPUQuota={}%", u64::from(pod.size.vcpus) * 100),
                &format!("MemoryMax={}M", pod.size.memory_mib),
            ]),
        ]
    }

    pub fn freeze_argv(pod: &PodSpec) -> Vec<String> {
        argv(&["systemctl", "--user", "freeze", &Self::slice(pod)])
    }

    pub fn thaw_argv(pod: &PodSpec) -> Vec<String> {
        argv(&["systemctl", "--user", "thaw", &Self::slice(pod)])
    }

    pub fn stop_argv(&self, pod: &PodSpec) -> Vec<Vec<String>> {
        vec![
            // Thaw first: a frozen cgroup's processes cannot take the stop signal.
            argv(&["systemctl", "--user", "thaw", &Self::slice(pod)]),
            argv(&["systemctl", "--user", "stop", &Self::slice(pod)]),
            argv(&["rm", "-rf", "--", &self.root(pod)]),
        ]
    }

    pub fn exec_argv(&self, pod: &PodSpec, request: &ExecRequest) -> Vec<String> {
        let root = self.root(pod);
        let mut out = argv(&[
            "systemd-run",
            "--user",
            "--quiet",
            "--collect",
            "--wait",
            "--pipe",
            // systemd-run expands `$VAR` in the command by default, which would
            // rewrite the caller's argv (`$$` arrives as `$`). systemd 254+.
            "--expand-environment=no",
            &format!("--slice={}", Self::slice(pod)),
        ]);
        for (key, value) in &request.env {
            out.push(format!("--setenv={key}={value}"));
        }
        out.push("--".to_owned());
        out.extend(bwrap_argv(
            &self.pods_dir,
            &root,
            request.cwd.as_deref().unwrap_or(&root),
            &[],
            &request.program,
            &request.args,
        ));
        out
    }

    pub fn read_argv(&self, pod: &PodSpec, path: &PodPath) -> Vec<String> {
        argv(&["cat", "--", &format!("{}/{}", self.root(pod), path.as_str())])
    }

    pub fn write_argv(&self, pod: &PodSpec, path: &PodPath) -> Vec<String> {
        let full = format!("{}/{}", self.root(pod), path.as_str());
        argv(&["sh", "-c", "mkdir -p -- \"$(dirname -- \"$1\")\" && cat > \"$1\"", "sh", &full])
    }

    async fn ok(&self, pod: &PodSpec, argv: &[String], stdin: &[u8]) -> Result<ExecOutput, String> {
        let out = self.runner.run(&pod.host, argv, stdin).await?;
        if out.exit_code != 0 {
            return Err(format!(
                "{} exited {} on {}: {}",
                argv.first().map(String::as_str).unwrap_or(""),
                out.exit_code,
                pod.host,
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(out)
    }
}

/// The host's system dirs a pod sees, read-only. Not `/` itself: `bwrap` without setuid runs in a
/// user namespace that maps no root, so a root-owned `/` or `/home` reads as owned by
/// another user (the overflow uid) there, and a pod's own `acpmux` refuses such an ancestor of
/// its state dir. Every dir `bwrap` makes on its own root (`/`, the root's parents) is the pod
/// user's instead. Users' homes stay out: a pod sees only its own root.
pub const SYSTEM_DIRS: &[&str] = &[
    "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc", "/opt", "/var", "/srv",
    "/run", "/mnt", "/media", "/sys", "/nix", "/snap",
];

/// `bwrap` around one program, the pod's whole view of its host: the [`SYSTEM_DIRS`], the
/// host's `binds` and the program read-only, its own pid and IPC namespaces, a private `/tmp`,
/// and its own root.
pub fn bwrap_argv(
    pods_dir: &str,
    root: &str,
    cwd: &str,
    binds: &[String],
    program: &str,
    args: &[String],
) -> Vec<String> {
    let mut out = argv(&["bwrap", "--die-with-parent", "--unshare-pid", "--unshare-ipc"]);
    for dir in SYSTEM_DIRS {
        out.extend(argv(&["--ro-bind-try", dir, dir]));
    }
    // What the host names for every pod, at its own path: a harness installed under a home
    // (a native `claude` in `~/.local`), which the system dirs leave out.
    for path in binds {
        out.extend(argv(&["--ro-bind-try", path, path]));
    }
    // An init under a home (a lane's own build of `acpmux`) is visible at its own path.
    if program.starts_with('/') {
        out.extend(argv(&["--ro-bind-try", program, program]));
    }
    out.extend(argv(&[
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        // Hide every other pod: an empty tmpfs over the pods dir, then
        // this pod's root alone on top of it.
        "--tmpfs",
        pods_dir,
        // Same path inside and out, so files and exec agree; `bwrap`
        // makes its parents, owned by the pod user.
        "--bind",
        root,
        root,
        "--setenv",
        "CMUX_POD_ROOT",
        root,
        "--chdir",
        cwd,
        "--",
        program,
    ]));
    out.extend(args.iter().cloned());
    out
}

pub(crate) fn argv(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| (*s).to_owned()).collect()
}

#[async_trait]
impl<X: CommandRunner> PodRuntime for SystemdPodRuntime<X> {
    async fn start(&self, pod: &PodSpec) -> Result<(), String> {
        for cmd in self.start_argv(pod) {
            self.ok(pod, &cmd, &[]).await?;
        }
        Ok(())
    }

    async fn freeze(&self, pod: &PodSpec) -> Result<(), String> {
        self.ok(pod, &Self::freeze_argv(pod), &[]).await.map(drop)
    }

    async fn thaw(&self, pod: &PodSpec) -> Result<(), String> {
        self.ok(pod, &Self::thaw_argv(pod), &[]).await.map(drop)
    }

    async fn stop(&self, pod: &PodSpec) -> Result<(), String> {
        let cmds = self.stop_argv(pod);
        // Thaw and stop fail harmlessly when the slice is already gone.
        for cmd in cmds.iter().take(2) {
            let _ = self.runner.run(&pod.host, cmd, &[]).await?;
        }
        let Some(stop) = cmds.get(2) else {
            return Err("stop command list is missing its final command".to_owned());
        };
        self.ok(pod, stop, &[]).await.map(drop)
    }

    async fn read_file(&self, pod: &PodSpec, path: &PodPath) -> Result<Vec<u8>, String> {
        self.ok(pod, &self.read_argv(pod, path), &[]).await.map(|o| o.stdout)
    }

    async fn write_file(
        &self,
        pod: &PodSpec,
        path: &PodPath,
        contents: &[u8],
    ) -> Result<(), String> {
        self.ok(pod, &self.write_argv(pod, path), contents).await.map(drop)
    }

    async fn exec(&self, pod: &PodSpec, request: &ExecRequest) -> Result<ExecOutput, String> {
        // The program's own exit code is the answer, not an error.
        self.runner.run(&pod.host, &self.exec_argv(pod, request), &request.stdin).await
    }
}
