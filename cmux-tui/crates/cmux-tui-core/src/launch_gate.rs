//! Durable launch barrier for canonical terminal children.
//!
//! A PTY first runs the current cmux executable in a private helper mode. The
//! helper proves its kernel process identity, receives the real argv, and then
//! waits. Dropping the parent endpoint before release makes the helper exit
//! without executing user code. A successful release preserves the PTY child
//! PID, cwd, environment, and controlling terminal across `exec`.
//!
//! Durable topology creation, materialization, replacement, legacy control
//! mutations, and ensure-terminal batches use this barrier. Daemon recovery is
//! intentionally ungated because the recovered recipe was already durable;
//! the sidebar plugin is intentionally ungated because it has no durable
//! topology identity.
//!
//! Before READY, the helper resolves and checks the exact executable under the
//! inherited cwd and PATH. After the topology append is fsynced, the parent
//! releases `exec`, observes the close-on-exec gate descriptor close, and then
//! writes the complete initial input while holding an exclusive PTY-input
//! reservation. A retry of the committed request therefore cannot replay
//! initial input.
//!
//! On macOS, release additionally requires a kernel `NOTE_EXEC` event for the
//! exact child PID. Close-on-exec EOF alone is insufficient because a helper
//! killed between release and `exec` closes the same descriptor. Other Unix
//! platforms retain the weaker EOF/error-pipe protocol and do not claim this
//! exact exec proof.
//!
//! Generic initial input is limited to canonical-safe records. Arbitrary raw
//! bootstrapping that depends on application termios readiness requires an
//! explicit application-specific readiness protocol outside this barrier.
//!
//! This is a pre-exec durability guarantee, not exactly-once command execution
//! across every daemon crash. A crash after release can leave the command
//! running or terminate it with the PTY, and recovery may start the durable
//! recipe again. Release uncertainty is returned as a typed quarantine
//! outcome. The session owner must retain that attempt and must never retry
//! its initial input as a new launch.

#[cfg(not(unix))]
use portable_pty::CommandBuilder;

const HIDDEN_GATE_ARGUMENT: &str = "__cmux-internal-terminal-launch-gate-v1";
const GATE_SOCKET_ENV: &str = "CMUX_INTERNAL_LAUNCH_GATE_SOCKET";
const GATE_TOKEN_ENV: &str = "CMUX_INTERNAL_LAUNCH_GATE_TOKEN";

#[derive(Debug)]
pub(crate) struct TerminalLaunchReleaseFailure {
    pub message: String,
}

#[derive(Debug)]
pub(crate) enum TerminalLaunchReleaseOutcome {
    Activated,
    Quarantined(TerminalLaunchReleaseFailure),
}

impl TerminalLaunchReleaseOutcome {
    fn into_result(self) -> anyhow::Result<()> {
        match self {
            Self::Activated => Ok(()),
            Self::Quarantined(failure) => anyhow::bail!(failure.message),
        }
    }
}

pub(crate) fn is_reserved_environment_name(name: &str) -> bool {
    matches!(name, GATE_SOCKET_ENV | GATE_TOKEN_ENV)
}

#[cfg(unix)]
mod unix {
    use std::fs;
    use std::io::{Read, Write};
    use std::net::Shutdown;
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::time::Duration;
    #[cfg(target_os = "macos")]
    use std::time::Instant;

    use anyhow::Context;
    use portable_pty::CommandBuilder;

    use super::{GATE_SOCKET_ENV, GATE_TOKEN_ENV, HIDDEN_GATE_ARGUMENT};

    const HELLO_MAGIC: &[u8; 8] = b"CMUXLGH1";
    const READY_MAGIC: &[u8; 8] = b"CMUXLGR1";
    const RELEASE_MAGIC: &[u8; 8] = b"CMUXLGX1";
    const EXEC_FAILURE_MAGIC: &[u8; 8] = b"CMUXLGF1";
    const TOKEN_BYTES: usize = 32;
    const MAX_SPEC_BYTES: usize = 4 * 1024 * 1024;
    const READY_DEADLINE: Duration = Duration::from_secs(10);
    const RELEASE_ACK_DEADLINE: Duration = Duration::from_secs(10);

    pub(crate) struct PendingTerminalLaunchGate {
        listener: UnixListener,
        paths: Option<GatePaths>,
        token: [u8; TOKEN_BYTES],
        encoded_argv: Vec<u8>,
    }

    pub(crate) struct TerminalLaunchGate {
        stream: UnixStream,
        #[cfg(target_os = "macos")]
        process_id: u32,
    }

    #[cfg(target_os = "macos")]
    struct ProcessExecWatcher {
        queue: libc::c_int,
        process_id: u32,
    }

    struct GatePaths {
        directory: PathBuf,
        socket: PathBuf,
    }

    impl PendingTerminalLaunchGate {
        pub(crate) fn new(argv: &[String]) -> anyhow::Result<Self> {
            if argv.is_empty() || argv[0].is_empty() {
                anyhow::bail!("terminal launch argv[0] must be non-empty");
            }
            if argv.iter().any(|argument| argument.contains('\0')) {
                anyhow::bail!("terminal launch argv contains NUL");
            }
            let encoded_argv = serde_json::to_vec(argv)?;
            if encoded_argv.len() > MAX_SPEC_BYTES {
                anyhow::bail!("terminal launch gate payload exceeds {MAX_SPEC_BYTES} bytes");
            }

            let token = random_token()?;
            let directory = PathBuf::from("/tmp").join(format!(
                "cmux-lg-{}-{}",
                unsafe { libc::geteuid() },
                uuid::Uuid::new_v4()
            ));
            let mut builder = fs::DirBuilder::new();
            builder.mode(0o700);
            builder
                .create(&directory)
                .with_context(|| format!("create launch gate directory {}", directory.display()))?;
            let socket = directory.join("gate.sock");
            crate::platform::validate_unix_socket_path(&socket)?;
            let paths = GatePaths { directory, socket };
            let listener = match UnixListener::bind(&paths.socket) {
                Ok(listener) => listener,
                Err(error) => {
                    drop(paths);
                    return Err(error.into());
                }
            };
            fs::set_permissions(&paths.socket, fs::Permissions::from_mode(0o600))?;
            Ok(Self { listener, paths: Some(paths), token, encoded_argv })
        }

        pub(crate) fn helper_command(&self) -> anyhow::Result<CommandBuilder> {
            let executable = helper_executable()?;
            let mut command = CommandBuilder::new(executable);
            #[cfg(not(test))]
            command.arg(HIDDEN_GATE_ARGUMENT);
            #[cfg(test)]
            command.args([
                "--exact",
                "launch_gate::unix::tests::subprocess_helper_entrypoint",
                "--nocapture",
            ]);
            self.apply_private_environment(&mut command);
            Ok(command)
        }

        pub(crate) fn apply_private_environment(&self, command: &mut CommandBuilder) {
            let paths = self.paths.as_ref().expect("pending launch gate retains paths");
            command.env(GATE_SOCKET_ENV, &paths.socket);
            command.env(GATE_TOKEN_ENV, token_string(&self.token));
        }

        pub(crate) fn finish(
            mut self,
            expected_process_id: Option<u32>,
        ) -> anyhow::Result<TerminalLaunchGate> {
            let expected_process_id = expected_process_id
                .ok_or_else(|| anyhow::anyhow!("launch gate child has no process identity"))?;
            wait_readable(&self.listener, READY_DEADLINE)?;
            let (mut stream, _) = self.listener.accept()?;
            stream.set_read_timeout(Some(READY_DEADLINE))?;
            stream.set_write_timeout(Some(READY_DEADLINE))?;

            let credentials = crate::platform::transport::Stream::peer_credentials(&stream)?
                .ok_or_else(|| anyhow::anyhow!("launch gate peer has no kernel credentials"))?;
            if credentials.user_id != unsafe { libc::geteuid() }
                || credentials.process_id != Some(expected_process_id)
            {
                anyhow::bail!(
                    "launch gate peer identity mismatch: expected uid {} pid {}, got uid {} pid {:?}",
                    unsafe { libc::geteuid() },
                    expected_process_id,
                    credentials.user_id,
                    credentials.process_id
                );
            }

            let mut hello = [0u8; HELLO_MAGIC.len() + TOKEN_BYTES];
            stream.read_exact(&mut hello)?;
            if &hello[..HELLO_MAGIC.len()] != HELLO_MAGIC
                || hello[HELLO_MAGIC.len()..] != self.token
            {
                anyhow::bail!("launch gate helper authentication failed");
            }

            let length = u32::try_from(self.encoded_argv.len())?.to_be_bytes();
            stream.write_all(&length)?;
            stream.write_all(&self.encoded_argv)?;
            stream.flush()?;
            let mut ready = [0u8; READY_MAGIC.len()];
            stream.read_exact(&mut ready)?;
            if &ready != READY_MAGIC {
                anyhow::bail!("launch gate helper sent an invalid ready acknowledgement");
            }

            if let Some(paths) = self.paths.take() {
                paths.remove_now()?;
            }
            Ok(TerminalLaunchGate {
                stream,
                #[cfg(target_os = "macos")]
                process_id: expected_process_id,
            })
        }
    }

    fn helper_executable() -> anyhow::Result<PathBuf> {
        let current = std::env::current_exe().context("resolve current launch gate executable")?;
        #[cfg(not(test))]
        if current.parent().and_then(Path::file_name).is_some_and(|name| name == "deps") {
            let profile = current.parent().and_then(Path::parent).ok_or_else(|| {
                anyhow::anyhow!("integration test helper has no profile directory")
            })?;
            let candidate =
                profile.join(format!("cmux-launch-gate-helper{}", std::env::consts::EXE_SUFFIX));
            let metadata = fs::symlink_metadata(&candidate).with_context(|| {
                format!("resolve dedicated integration launch-gate helper {}", candidate.display())
            })?;
            if !metadata.file_type().is_file()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.permissions().mode() & 0o022 != 0
            {
                anyhow::bail!(
                    "integration launch-gate helper is not a trusted owner-only executable: {}",
                    candidate.display()
                );
            }
            return candidate.canonicalize().with_context(|| {
                format!("canonicalize launch-gate helper {}", candidate.display())
            });
        }
        Ok(current)
    }

    impl TerminalLaunchGate {
        pub(crate) fn release(self) -> anyhow::Result<()> {
            self.release_resolved().into_result()
        }

        pub(crate) fn release_resolved(self) -> super::TerminalLaunchReleaseOutcome {
            match self.release_inner() {
                Ok(()) => super::TerminalLaunchReleaseOutcome::Activated,
                Err(error) => super::TerminalLaunchReleaseOutcome::Quarantined(
                    super::TerminalLaunchReleaseFailure { message: format!("{error:#}") },
                ),
            }
        }

        fn release_inner(mut self) -> anyhow::Result<()> {
            #[cfg(target_os = "macos")]
            let exec_deadline = Instant::now() + RELEASE_ACK_DEADLINE;
            #[cfg(target_os = "macos")]
            let exec_watcher = ProcessExecWatcher::new(self.process_id)
                .context("register exact-child exec witness before release")?;
            self.stream.set_read_timeout(Some(RELEASE_ACK_DEADLINE))?;
            self.stream.set_write_timeout(Some(RELEASE_ACK_DEADLINE))?;
            self.stream.write_all(RELEASE_MAGIC)?;
            self.stream.flush()?;
            let mut first = [0u8; 1];
            match self.stream.read(&mut first) {
                Ok(0) => {
                    #[cfg(target_os = "macos")]
                    return exec_watcher
                        .require_exec_before(exec_deadline)
                        .context("prove exact terminal child exec after release");
                    #[cfg(not(target_os = "macos"))]
                    return Ok(());
                }
                Ok(1) => {}
                Ok(_) => unreachable!("one-byte launch gate read returned more than one byte"),
                Err(error) => return Err(error.into()),
            }
            let mut failure_magic = [0u8; EXEC_FAILURE_MAGIC.len()];
            failure_magic[0] = first[0];
            self.stream.read_exact(&mut failure_magic[1..])?;
            if &failure_magic != EXEC_FAILURE_MAGIC {
                anyhow::bail!("launch gate helper sent an invalid exec result");
            }
            let mut length = [0u8; 4];
            self.stream.read_exact(&mut length)?;
            let length = u32::from_be_bytes(length) as usize;
            if length == 0 || length > 64 * 1024 {
                anyhow::bail!("launch gate helper sent an invalid exec failure length");
            }
            let mut message = vec![0u8; length];
            self.stream.read_exact(&mut message)?;
            anyhow::bail!(
                "terminal exec failed after durable commit: {}",
                String::from_utf8_lossy(&message)
            )
        }
    }

    #[cfg(target_os = "macos")]
    impl ProcessExecWatcher {
        fn new(process_id: u32) -> std::io::Result<Self> {
            let queue = unsafe { libc::kqueue() };
            if queue < 0 {
                return Err(std::io::Error::last_os_error());
            }
            let watcher = Self { queue, process_id };
            let change = libc::kevent {
                ident: process_id as libc::uintptr_t,
                filter: libc::EVFILT_PROC,
                flags: libc::EV_ADD | libc::EV_ONESHOT,
                fflags: libc::NOTE_EXEC | libc::NOTE_EXIT,
                data: 0,
                udata: std::ptr::null_mut(),
            };
            if unsafe {
                libc::kevent(watcher.queue, &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
            } < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(watcher)
        }

        fn require_exec_before(self, deadline: Instant) -> std::io::Result<()> {
            let event = self.wait_event_before(deadline)?;
            Self::require_exec_event(self.process_id, event)
        }

        fn wait_event_before(&self, deadline: Instant) -> std::io::Result<libc::kevent> {
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let timeout = libc::timespec {
                    tv_sec: remaining.as_secs().try_into().unwrap_or(libc::time_t::MAX),
                    tv_nsec: remaining.subsec_nanos().into(),
                };
                let mut event = std::mem::MaybeUninit::<libc::kevent>::zeroed();
                let count = unsafe {
                    libc::kevent(self.queue, std::ptr::null(), 0, event.as_mut_ptr(), 1, &timeout)
                };
                if count < 0 {
                    let error = std::io::Error::last_os_error();
                    if error.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                if count == 0 {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        format!("terminal child {} exec witness deadline elapsed", self.process_id),
                    ));
                }
                let event = unsafe { event.assume_init() };
                if event.ident != self.process_id as libc::uintptr_t
                    || event.filter != libc::EVFILT_PROC
                {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "terminal exec watcher received an event for another process",
                    ));
                }
                if event.flags & libc::EV_ERROR != 0 && event.data != 0 {
                    return Err(std::io::Error::from_raw_os_error(event.data as i32));
                }
                return Ok(event);
            }
        }

        fn require_exec_event(process_id: u32, event: libc::kevent) -> std::io::Result<()> {
            // Process notes may coalesce. An observed exec is authoritative even
            // when the same delivery reports that a very short-lived target has
            // already exited.
            if event.fflags & libc::NOTE_EXEC != 0 {
                return Ok(());
            }
            if event.fflags & libc::NOTE_EXIT != 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::ConnectionAborted,
                    format!("terminal child {process_id} exited before exec"),
                ));
            }
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "terminal exec watcher received neither NOTE_EXEC nor NOTE_EXIT",
            ))
        }
    }

    #[cfg(target_os = "macos")]
    impl Drop for ProcessExecWatcher {
        fn drop(&mut self) {
            unsafe {
                libc::close(self.queue);
            }
        }
    }

    impl Drop for TerminalLaunchGate {
        fn drop(&mut self) {
            let _ = self.stream.shutdown(Shutdown::Both);
        }
    }

    impl GatePaths {
        fn remove_now(self) -> std::io::Result<()> {
            match fs::remove_file(&self.socket) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
            match fs::remove_dir(&self.directory) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(error),
            }
        }
    }

    impl Drop for GatePaths {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.socket);
            let _ = fs::remove_dir(&self.directory);
        }
    }

    pub(crate) fn run_if_requested(args: &[String]) -> Option<anyhow::Result<()>> {
        (args.len() == 1 && args[0] == HIDDEN_GATE_ARGUMENT).then(run_child)
    }

    fn run_child() -> anyhow::Result<()> {
        let socket = std::env::var_os(GATE_SOCKET_ENV)
            .map(PathBuf::from)
            .ok_or_else(|| anyhow::anyhow!("launch gate socket is missing"))?;
        let token = std::env::var(GATE_TOKEN_ENV).context("launch gate token is missing")?;
        // Internal bootstrap details must not survive into the user process.
        unsafe {
            std::env::remove_var(GATE_SOCKET_ENV);
            std::env::remove_var(GATE_TOKEN_ENV);
        }
        validate_child_socket(&socket)?;
        let token = parse_token(&token)?;
        let mut stream = UnixStream::connect(&socket)?;
        stream.set_write_timeout(Some(READY_DEADLINE))?;
        stream.write_all(HELLO_MAGIC)?;
        stream.write_all(&token)?;
        stream.flush()?;

        let mut length = [0u8; 4];
        stream.read_exact(&mut length)?;
        let length = u32::from_be_bytes(length) as usize;
        if length == 0 || length > MAX_SPEC_BYTES {
            anyhow::bail!("launch gate received an invalid argv payload length");
        }
        let mut encoded = vec![0u8; length];
        stream.read_exact(&mut encoded)?;
        let argv: Vec<String> = serde_json::from_slice(&encoded)?;
        if argv.is_empty() || argv[0].is_empty() || argv.iter().any(|value| value.contains('\0')) {
            anyhow::bail!("launch gate received invalid argv");
        }
        let executable = resolve_executable(&argv[0])?;
        #[cfg(test)]
        if std::env::var_os(test_support::FAIL_BEFORE_READY_ENV).is_some() {
            anyhow::bail!("injected launch gate failure before ready");
        }
        set_close_on_exec(&stream)?;
        #[cfg(test)]
        if std::env::var_os(test_support::ASSERT_UNBOUNDED_RELEASE_ENV).is_some()
            && stream.read_timeout()?.is_some()
        {
            anyhow::bail!("launch gate helper release wait has a wall-clock deadline");
        }
        stream.write_all(READY_MAGIC)?;
        stream.flush()?;

        let mut release = [0u8; RELEASE_MAGIC.len()];
        match stream.read_exact(&mut release) {
            Ok(()) if &release == RELEASE_MAGIC => {}
            Ok(()) => anyhow::bail!("launch gate received an invalid release message"),
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error.into()),
        }
        #[cfg(test)]
        if std::env::var_os(test_support::DIE_AFTER_RELEASE_ENV).is_some() {
            unsafe {
                libc::_exit(125);
            }
        }
        use std::os::unix::process::CommandExt;
        let error = Command::new(&executable).arg0(&argv[0]).args(&argv[1..]).exec();
        let message = format!("{}: {error}", executable.display());
        let bytes = message.as_bytes();
        let length = u32::try_from(bytes.len()).unwrap_or(u32::MAX).to_be_bytes();
        let _ = stream.write_all(EXEC_FAILURE_MAGIC);
        let _ = stream.write_all(&length);
        let _ = stream.write_all(bytes);
        let _ = stream.flush();
        Err(error).with_context(|| format!("exec terminal command {:?}", argv[0]))
    }

    fn resolve_executable(program: &str) -> anyhow::Result<PathBuf> {
        let cwd = std::env::current_dir().context("resolve launch gate cwd")?;
        if program.as_bytes().contains(&b'/') {
            return resolve_executable_in(program, &cwd, std::ffi::OsStr::new(""));
        }
        let search_path = std::env::var_os("PATH")
            .ok_or_else(|| anyhow::anyhow!("terminal launch PATH is unavailable"))?;
        resolve_executable_in(program, &cwd, &search_path)
    }

    fn resolve_executable_in(
        program: &str,
        cwd: &Path,
        search_path: &std::ffi::OsStr,
    ) -> anyhow::Result<PathBuf> {
        let path = Path::new(program);
        if program.as_bytes().contains(&b'/') {
            let candidate = if path.is_absolute() { path.to_path_buf() } else { cwd.join(path) };
            return validate_executable(candidate);
        }
        let mut errors = Vec::new();
        for directory in std::env::split_paths(search_path) {
            let candidate = if directory.is_absolute() {
                directory.join(path)
            } else {
                cwd.join(directory).join(path)
            };
            match validate_executable(candidate) {
                Ok(executable) => return Ok(executable),
                Err(error) => errors.push(error.to_string()),
            }
        }
        anyhow::bail!(
            "unable to resolve terminal executable {program:?} in PATH: {}",
            errors.join("; ")
        )
    }

    fn validate_executable(candidate: PathBuf) -> anyhow::Result<PathBuf> {
        match fs::metadata(&candidate) {
            Ok(metadata) if metadata.is_dir() => {
                anyhow::bail!("terminal executable is a directory: {}", candidate.display())
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                anyhow::bail!("terminal executable does not exist: {}", candidate.display())
            }
            Err(error) => return Err(error.into()),
        }
        let c_path = std::ffi::CString::new(candidate.as_os_str().as_bytes())?;
        if unsafe { libc::access(c_path.as_ptr(), libc::X_OK) } != 0 {
            anyhow::bail!("terminal executable is not executable: {}", candidate.display());
        }
        Ok(candidate)
    }

    fn set_close_on_exec(stream: &UnixStream) -> std::io::Result<()> {
        let descriptor = stream.as_raw_fd();
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
        if flags < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }

    fn wait_readable(listener: &UnixListener, timeout: Duration) -> std::io::Result<()> {
        let mut descriptor =
            libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let timeout_ms = i32::try_from(timeout.as_millis()).unwrap_or(i32::MAX);
        loop {
            let status = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
            if status > 0 && descriptor.revents & libc::POLLIN != 0 {
                return Ok(());
            }
            if status == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "launch gate helper readiness deadline elapsed",
                ));
            }
            if status < 0
                && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
            {
                continue;
            }
            if status < 0 {
                return Err(std::io::Error::last_os_error());
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::ConnectionAborted,
                "launch gate listener closed before helper connected",
            ));
        }
    }

    fn validate_child_socket(socket: &Path) -> anyhow::Result<()> {
        crate::platform::validate_unix_socket_path(socket)?;
        let parent =
            socket.parent().ok_or_else(|| anyhow::anyhow!("launch gate socket has no parent"))?;
        let parent_metadata = fs::symlink_metadata(parent)?;
        let socket_metadata = fs::symlink_metadata(socket)?;
        let expected_uid = unsafe { libc::geteuid() };
        let expected_prefix = format!("cmux-lg-{expected_uid}-");
        if !parent.is_absolute()
            || !parent
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(&expected_prefix))
            || parent_metadata.file_type().is_symlink()
            || !parent_metadata.is_dir()
            || parent_metadata.uid() != expected_uid
            || parent_metadata.permissions().mode() & 0o777 != 0o700
            || socket.file_name().and_then(|name| name.to_str()) != Some("gate.sock")
            || !socket_metadata.file_type().is_socket()
            || socket_metadata.uid() != expected_uid
            || socket_metadata.permissions().mode() & 0o777 != 0o600
        {
            anyhow::bail!("launch gate socket failed private path validation");
        }
        Ok(())
    }

    fn random_token() -> anyhow::Result<[u8; TOKEN_BYTES]> {
        let mut token = [0u8; TOKEN_BYTES];
        getrandom::fill(&mut token)?;
        Ok(token)
    }

    fn token_string(token: &[u8; TOKEN_BYTES]) -> String {
        token.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    fn parse_token(value: &str) -> anyhow::Result<[u8; TOKEN_BYTES]> {
        if value.len() != TOKEN_BYTES * 2 {
            anyhow::bail!("launch gate token has invalid length");
        }
        let mut token = [0u8; TOKEN_BYTES];
        for (index, byte) in token.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16)
                .context("launch gate token contains invalid hex")?;
        }
        Ok(token)
    }

    #[cfg(test)]
    pub(crate) mod test_support {
        pub(crate) const ASSERT_UNBOUNDED_RELEASE_ENV: &str =
            "CMUX_TEST_LAUNCH_GATE_ASSERT_UNBOUNDED_RELEASE";
        pub(crate) const DIE_AFTER_RELEASE_ENV: &str = "CMUX_TEST_LAUNCH_GATE_DIE_AFTER_RELEASE";
        pub(crate) const EXIT_MARKER_ENV: &str = "CMUX_TEST_LAUNCH_GATE_EXIT_MARKER";
        pub(crate) const FAIL_BEFORE_READY_ENV: &str = "CMUX_TEST_LAUNCH_GATE_FAIL_BEFORE_READY";
        pub(crate) const IGNORE_HUP_ENV: &str = "CMUX_TEST_LAUNCH_GATE_IGNORE_HUP";
    }

    #[cfg(test)]
    mod tests {
        #[cfg(target_os = "macos")]
        use std::mem::{size_of, size_of_val};
        use std::os::unix::fs::PermissionsExt;

        #[cfg(target_os = "macos")]
        use portable_pty::{PtySize, native_pty_system};

        fn fixture() -> std::path::PathBuf {
            let path = std::env::temp_dir().join(format!(
                "cmux-launch-resolve-{}-{}",
                std::process::id(),
                uuid::Uuid::new_v4()
            ));
            std::fs::create_dir(&path).unwrap();
            path
        }

        fn executable(path: &std::path::Path) {
            std::fs::write(path, b"#!/bin/sh\nexit 0\n").unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }

        #[test]
        fn executable_resolution_rejects_missing_non_executable_and_directory_targets() {
            let root = fixture();
            let missing =
                super::resolve_executable_in("./missing", &root, std::ffi::OsStr::new(""))
                    .unwrap_err();
            assert!(missing.to_string().contains("does not exist"));

            let non_executable = root.join("plain");
            std::fs::write(&non_executable, b"plain").unwrap();
            std::fs::set_permissions(&non_executable, std::fs::Permissions::from_mode(0o600))
                .unwrap();
            let denied = super::resolve_executable_in("./plain", &root, std::ffi::OsStr::new(""))
                .unwrap_err();
            assert!(denied.to_string().contains("not executable"));

            std::fs::create_dir(root.join("folder")).unwrap();
            let directory =
                super::resolve_executable_in("./folder", &root, std::ffi::OsStr::new(""))
                    .unwrap_err();
            assert!(directory.to_string().contains("is a directory"));
            std::fs::remove_dir_all(root).unwrap();
        }

        #[test]
        fn executable_resolution_preserves_relative_and_path_lookup_semantics() {
            let root = fixture();
            let relative = root.join("relative-tool");
            executable(&relative);
            assert_eq!(
                super::resolve_executable_in(
                    "./relative-tool",
                    &root,
                    std::ffi::OsStr::new("unused"),
                )
                .unwrap(),
                relative
            );

            let bin = root.join("bin");
            std::fs::create_dir(&bin).unwrap();
            let path_tool = bin.join("path-tool");
            executable(&path_tool);
            assert_eq!(
                super::resolve_executable_in("path-tool", &root, std::ffi::OsStr::new("bin"))
                    .unwrap(),
                path_tool
            );
            std::fs::remove_dir_all(root).unwrap();
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn exact_exec_witness_rejects_helper_death_after_release() {
            let pending =
                super::PendingTerminalLaunchGate::new(&["/usr/bin/true".to_string()]).unwrap();
            let pty = native_pty_system()
                .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
                .unwrap();
            let mut command = pending.helper_command().unwrap();
            command.env(super::test_support::DIE_AFTER_RELEASE_ENV, "1");
            let mut child = pty.slave.spawn_command(command).unwrap();
            let gate = pending.finish(child.process_id()).unwrap();
            drop(pty.slave);

            let super::super::TerminalLaunchReleaseOutcome::Quarantined(failure) =
                gate.release_resolved()
            else {
                panic!("helper death must quarantine the launch");
            };
            assert!(failure.message.contains("exited before exec"), "{}", failure.message);
            child.wait().unwrap();
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn helper_release_wait_is_configured_without_a_child_deadline() {
            let pending =
                super::PendingTerminalLaunchGate::new(&["/usr/bin/true".to_string()]).unwrap();
            let pty = native_pty_system()
                .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
                .unwrap();
            let mut command = pending.helper_command().unwrap();
            command.env(super::test_support::ASSERT_UNBOUNDED_RELEASE_ENV, "1");
            let mut child = pty.slave.spawn_command(command).unwrap();
            let gate = pending.finish(child.process_id()).unwrap();
            drop(pty.slave);

            gate.release().unwrap();
            child.wait().unwrap();
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn exact_exec_witness_accepts_coalesced_exec_and_exit() {
            let executable = std::ffi::CString::new("/usr/bin/true").unwrap();
            let mut release_pipe = [0; 2];
            assert_eq!(unsafe { libc::pipe(release_pipe.as_mut_ptr()) }, 0);
            let process_id = unsafe { libc::fork() };
            assert!(process_id >= 0, "fork failed: {}", std::io::Error::last_os_error());
            if process_id == 0 {
                unsafe {
                    libc::close(release_pipe[1]);
                    let mut release = 0u8;
                    if libc::read(
                        release_pipe[0],
                        (&mut release as *mut u8).cast(),
                        size_of_val(&release),
                    ) == 1
                    {
                        libc::execl(
                            executable.as_ptr(),
                            executable.as_ptr(),
                            std::ptr::null::<libc::c_char>(),
                        );
                    }
                    libc::_exit(126);
                }
            }

            unsafe {
                libc::close(release_pipe[0]);
            }
            let watcher = super::ProcessExecWatcher::new(process_id as u32).unwrap();
            assert_eq!(
                unsafe {
                    libc::write(release_pipe[1], (&1u8 as *const u8).cast(), size_of::<u8>())
                },
                1
            );
            unsafe {
                libc::close(release_pipe[1]);
            }
            let mut status = 0;
            assert_eq!(unsafe { libc::waitpid(process_id, &mut status, 0) }, process_id);
            assert!(libc::WIFEXITED(status));
            assert_eq!(libc::WEXITSTATUS(status), 0);

            let event = watcher
                .wait_event_before(std::time::Instant::now() + super::RELEASE_ACK_DEADLINE)
                .unwrap();
            assert_ne!(event.fflags & libc::NOTE_EXEC, 0);
            assert_ne!(event.fflags & libc::NOTE_EXIT, 0);
            super::ProcessExecWatcher::require_exec_event(process_id as u32, event).unwrap();
        }

        #[test]
        fn subprocess_helper_entrypoint() {
            if std::env::var_os(super::GATE_SOCKET_ENV).is_none() {
                return;
            }
            if std::env::var_os(super::test_support::IGNORE_HUP_ENV).is_some() {
                unsafe {
                    libc::signal(libc::SIGHUP, libc::SIG_IGN);
                }
            }
            let result = super::run_child();
            if let Some(marker) = std::env::var_os(super::test_support::EXIT_MARKER_ENV) {
                std::fs::write(marker, b"exited").unwrap();
            }
            result.unwrap();
        }
    }
}

#[cfg(all(unix, test))]
pub(crate) use unix::test_support;
#[cfg(unix)]
pub(crate) use unix::{PendingTerminalLaunchGate, TerminalLaunchGate, run_if_requested};

#[cfg(not(unix))]
pub(crate) struct PendingTerminalLaunchGate;

#[cfg(not(unix))]
pub(crate) struct TerminalLaunchGate;

#[cfg(not(unix))]
impl PendingTerminalLaunchGate {
    pub(crate) fn new(_argv: &[String]) -> anyhow::Result<Self> {
        anyhow::bail!("durable terminal launch gates require Unix-domain sockets")
    }

    pub(crate) fn helper_command(&self) -> anyhow::Result<CommandBuilder> {
        unreachable!("unsupported launch gate cannot create a command")
    }

    pub(crate) fn apply_private_environment(&self, _command: &mut CommandBuilder) {
        unreachable!("unsupported launch gate has no private environment")
    }

    pub(crate) fn finish(
        self,
        _expected_process_id: Option<u32>,
    ) -> anyhow::Result<TerminalLaunchGate> {
        unreachable!("unsupported launch gate cannot finish")
    }
}

#[cfg(not(unix))]
impl TerminalLaunchGate {
    pub(crate) fn release(self) -> anyhow::Result<()> {
        self.release_resolved().into_result()
    }

    pub(crate) fn release_resolved(self) -> TerminalLaunchReleaseOutcome {
        TerminalLaunchReleaseOutcome::Quarantined(TerminalLaunchReleaseFailure {
            message: "durable terminal launch gates require Unix-domain sockets".to_string(),
        })
    }
}

#[cfg(not(unix))]
pub(crate) fn run_if_requested(args: &[String]) -> Option<anyhow::Result<()>> {
    (args.len() == 1 && args[0] == HIDDEN_GATE_ARGUMENT)
        .then(|| anyhow::bail!("durable terminal launch gates require Unix-domain sockets"))
}
