//! `cmux-vmd-guest`: the agent inside each microVM. Listens on vsock port 52 and serves ping,
//! exec, read-file and write-file, one framed request per connection (see `cmux_vmd::proto`).
//!
//! At start it applies the `cmux.ip6=ADDR/LEN,GW` and `cmux.dns=IP` kernel parameters the host
//! sets (IPv4 comes from the kernel's own `ip=`). Run it as root from the image's init.

use std::process::ExitCode;

#[cfg(target_os = "linux")]
fn main() -> ExitCode {
    match linux::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("cmux-vmd-guest: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() -> ExitCode {
    eprintln!("cmux-vmd-guest runs only inside a Linux microVM");
    ExitCode::FAILURE
}

#[cfg(target_os = "linux")]
mod linux {
    use std::fs::File;
    use std::io::{self, Read, Write};
    use std::os::fd::FromRawFd;
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD as B64;
    use cmux_process::{Command, Stdio};
    use cmux_vmd::proto::{GUEST_AGENT_PORT, GuestRequest, GuestResponse, read_frame, write_frame};

    pub fn run() -> io::Result<()> {
        apply_cmdline_network();
        let listener = vsock_listen(GUEST_AGENT_PORT)?;
        // One scoped thread per connection: the scope owns (and finally joins) every one.
        std::thread::scope(|s| {
            loop {
                // SAFETY: accept(2) on our listening socket; null address arguments are allowed.
                let fd = unsafe {
                    libc::accept4(
                        listener,
                        std::ptr::null_mut(),
                        std::ptr::null_mut(),
                        libc::SOCK_CLOEXEC,
                    )
                };
                if fd < 0 {
                    let e = io::Error::last_os_error();
                    if e.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(e);
                }
                // SAFETY: fd is a fresh connected socket that this File now owns.
                let conn = unsafe { File::from_raw_fd(fd) };
                s.spawn(move || serve(conn));
            }
        })
    }

    fn vsock_listen(port: u32) -> io::Result<libc::c_int> {
        // SAFETY: plain socket syscalls; the address struct is fully initialised before bind.
        unsafe {
            let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let mut addr: libc::sockaddr_vm = std::mem::zeroed();
            addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
            addr.svm_port = port;
            addr.svm_cid = libc::VMADDR_CID_ANY;
            let len = size_of::<libc::sockaddr_vm>() as libc::socklen_t;
            if libc::bind(fd, (&raw const addr).cast(), len) < 0 || libc::listen(fd, 128) < 0 {
                let e = io::Error::last_os_error();
                libc::close(fd);
                return Err(e);
            }
            Ok(fd)
        }
    }

    fn serve(mut conn: File) {
        let reply = match read_frame::<_, GuestRequest>(&mut conn) {
            Ok(req) => handle(req),
            Err(e) => GuestResponse::Error { message: format!("bad request: {e}") },
        };
        let _ = write_frame(&mut conn, &reply);
    }

    fn err(e: impl std::fmt::Display) -> GuestResponse {
        GuestResponse::Error { message: e.to_string() }
    }

    fn handle(req: GuestRequest) -> GuestResponse {
        match req {
            GuestRequest::Ping => GuestResponse::Pong { uptime_ms: uptime_ms() },
            GuestRequest::ReadFile { path } => match std::fs::read(&path) {
                Ok(data) => GuestResponse::File { data: B64.encode(data) },
                Err(e) => err(format!("{path}: {e}")),
            },
            GuestRequest::WriteFile { path, data, mode } => {
                let data = match B64.decode(data) {
                    Ok(d) => d,
                    Err(e) => return err(e),
                };
                if let Some(parent) = std::path::Path::new(&path).parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                match write_atomic(&path, &data, mode) {
                    Ok(()) => GuestResponse::Ok,
                    Err(e) => err(format!("{path}: {e}")),
                }
            }
            GuestRequest::Exec { program, args, env, cwd, stdin, timeout_ms } => {
                exec(program, args, env, cwd, stdin, timeout_ms)
            }
        }
    }

    /// Write through a temp file made with the final mode (a 0600 secret is never readable by
    /// others, not even for a moment), flushed to disk, then renamed over `path`: a reader sees
    /// the old file or the whole new one.
    fn write_atomic(path: &str, data: &[u8], mode: Option<u32>) -> io::Result<()> {
        use std::os::unix::fs::OpenOptionsExt;
        let tmp = format!("{path}.cmux-vmd-tmp");
        let result = (|| {
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(mode.unwrap_or(0o644))
                .open(&tmp)?;
            // The umask may have narrowed the mode at create, and a stale temp keeps its own.
            if let Some(m) = mode {
                f.set_permissions(std::fs::Permissions::from_mode(m))?;
            }
            f.write_all(data)?;
            f.sync_all()?;
            std::fs::rename(&tmp, path)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result
    }

    fn exec(
        program: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
        cwd: Option<String>,
        stdin: String,
        timeout_ms: u64,
    ) -> GuestResponse {
        let stdin = match B64.decode(stdin) {
            Ok(s) => s,
            Err(e) => return err(e),
        };
        let mut cmd = Command::new(&program);
        cmd.args(&args)
            .envs(env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);
        if let Some(cwd) = cwd {
            cmd.current_dir(cwd);
        }
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => return err(format!("spawn {program}: {e}")),
        };
        let pid = child.id();
        let (stdin_pipe, stdout_pipe, stderr_pipe) =
            (child.stdin.take(), child.stdout.take(), child.stderr.take());
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let status = std::thread::scope(|s| {
            if let Some(mut pipe) = stdin_pipe {
                s.spawn(move || {
                    let _ = pipe.write_all(&stdin);
                });
            }
            if let Some(mut pipe) = stdout_pipe {
                let out = &mut stdout;
                s.spawn(move || {
                    let _ = pipe.read_to_end(out);
                });
            }
            if let Some(mut pipe) = stderr_pipe {
                let out = &mut stderr;
                s.spawn(move || {
                    let _ = pipe.read_to_end(out);
                });
            }
            if timeout_ms == 0 {
                return child.wait();
            }
            match child.wait_timeout(Duration::from_millis(timeout_ms)) {
                Ok(Some(status)) => Ok(status),
                Ok(None) => {
                    // Over its time: end its whole group, so no grandchild keeps a pipe open.
                    if let Ok(p) = libc::pid_t::try_from(pid) {
                        // SAFETY: the group this unreaped child leads.
                        unsafe { libc::kill(-p, libc::SIGKILL) };
                    }
                    child.wait()
                }
                Err(e) => Err(e),
            }
        });
        match status {
            Ok(status) => GuestResponse::Exec {
                exit_code: status.code().unwrap_or(-1),
                stdout: B64.encode(stdout),
                stderr: B64.encode(stderr),
            },
            Err(e) => err(e),
        }
    }

    fn uptime_ms() -> u64 {
        let mut s = String::new();
        let _ = File::open("/proc/uptime").and_then(|mut f| f.read_to_string(&mut s));
        s.split_whitespace()
            .next()
            .and_then(|v| v.parse::<f64>().ok())
            .map(|v| (v * 1000.0) as u64)
            .unwrap_or(0)
    }

    fn apply_cmdline_network() {
        let cmdline = std::fs::read_to_string("/proc/cmdline").unwrap_or_default();
        for kv in cmdline.split_whitespace() {
            if let Some(v) = kv.strip_prefix("cmux.ip6=") {
                if let Some((addr, gw)) = v.split_once(',') {
                    let _ = Command::new("ip")
                        .args(["-6", "addr", "add", addr, "dev", "eth0", "nodad"])
                        .status();
                    let _ = Command::new("ip")
                        .args(["-6", "route", "add", "default", "via", gw])
                        .status();
                }
            } else if let Some(dns) = kv.strip_prefix("cmux.dns=") {
                let _ = std::fs::remove_file("/etc/resolv.conf");
                let _ = std::fs::write("/etc/resolv.conf", format!("nameserver {dns}\n"));
            }
        }
    }
}
