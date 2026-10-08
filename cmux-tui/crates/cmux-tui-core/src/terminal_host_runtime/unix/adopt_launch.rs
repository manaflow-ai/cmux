//! Adopt-launch mode (cx-6so.49 L1): a replacement terminal host that
//! serves the running session of a dead host from a PTY master the owner
//! kept in custody (`pty_custody.rs`).
//!
//! The owner starts `__terminal-host --bootstrap-stdio --adopt-pty-fd N`
//! with the master at descriptor `N`, sends `Bootstrap` (same terminal id
//! and owner token), then `LaunchAdopt` instead of `Launch`. The host takes
//! the incarnation's PTY ownership lock (`pty_lock.rs`) before it touches
//! the descriptor, then runs exactly like a normal host on that master: the
//! same terminal id and incarnation (the shell is the same run), a new
//! process, nonce and record at the same path. It spawns no child; the
//! adopted session ends as `exit-unobserved` (`adopted_child.rs`).

use std::os::fd::{FromRawFd, OwnedFd};

use super::adopted_child::AdoptedChild;
use super::pty_custody::PtyCustody;
use super::pty_lock::PtyOwnershipLock;
use super::*;

/// The launch fields of `Launch` plus the PTY and session to adopt, the
/// reused incarnation and a seed blob of VT replay. The seed may use the
/// full blob budget on top of the `Launch` budget.
const MAX_LAUNCH_ADOPT_PAYLOAD: usize = MAX_LAUNCH_PAYLOAD + size_of::<u32>() + MAX_BLOB;
const ADOPT_PTY_FD_FLAG: &str = "--adopt-pty-fd";
/// The descriptor the owner passes the master at.
const ADOPTED_PTY_FD: libc::c_int = 3;

/// The PTY and session an adopting host serves.
#[derive(Debug)]
pub(super) struct AdoptSpec {
    fd: RawFd,
    child_pid: u32,
    session_id: u32,
    seed: Vec<u8>,
}

#[derive(Debug)]
struct HostLaunchAdopt {
    launch: HostLaunch,
    child_pid: u32,
    session_id: u32,
    incarnation: HostIncarnation,
    seed: Vec<u8>,
}

impl HostLaunchAdopt {
    fn encode(&self) -> anyhow::Result<Vec<u8>> {
        let launch = &self.launch;
        let (cols, rows) = normalize_terminal_geometry(launch.cols, launch.rows)?;
        let cell_pixels = (launch.cell_pixels.0.max(1), launch.cell_pixels.1.max(1));
        pty_size(cols, rows, cell_pixels)?;
        anyhow::ensure!(self.child_pid != 0 && self.session_id != 0, "adopted session is unnamed");
        let mut output = Vec::new();
        put_string(&mut output, &launch.endpoint)?;
        put_string(&mut output, &launch.record_path)?;
        put_string(&mut output, &launch.term)?;
        output.extend_from_slice(&cols.to_le_bytes());
        output.extend_from_slice(&rows.to_le_bytes());
        output.extend_from_slice(
            &u32::try_from(launch.scrollback)
                .map_err(|_| anyhow::anyhow!("terminal-host scrollback is too large"))?
                .to_le_bytes(),
        );
        encode_default_colors(&mut output, launch.default_colors);
        output.extend_from_slice(&cell_pixels.0.to_le_bytes());
        output.extend_from_slice(&cell_pixels.1.to_le_bytes());
        encode_kitty_graphics_limits(&mut output, launch.kitty_graphics_limits)?;
        output.extend_from_slice(&self.child_pid.to_le_bytes());
        output.extend_from_slice(&self.session_id.to_le_bytes());
        output.extend_from_slice(self.incarnation.as_bytes());
        anyhow::ensure!(
            output.len() <= MAX_LAUNCH_PAYLOAD,
            "terminal-host adopt launch payload is too large"
        );
        put_blob(&mut output, &self.seed)?;
        Ok(output)
    }

    fn decode(payload: &[u8]) -> anyhow::Result<Self> {
        anyhow::ensure!(
            payload.len() <= MAX_LAUNCH_ADOPT_PAYLOAD,
            "terminal-host adopt launch payload is too large"
        );
        let mut decoder = PayloadDecoder::new(payload);
        let endpoint = decoder.string()?;
        let record_path = decoder.string()?;
        let term = decoder.string()?;
        let (cols, rows) = normalize_terminal_geometry(decoder.u16()?, decoder.u16()?)?;
        let scrollback = decoder.u32()? as usize;
        let default_colors = decode_default_colors(&mut decoder)?;
        let cell_pixels = (decoder.u16()?.max(1), decoder.u16()?.max(1));
        pty_size(cols, rows, cell_pixels)?;
        let kitty_graphics_limits = decode_kitty_graphics_limits(&mut decoder)?;
        let child_pid = decoder.u32()?;
        let session_id = decoder.u32()?;
        let incarnation_bytes: [u8; 16] = decoder.take(16)?.try_into()?;
        let incarnation = HostIncarnation::from_hex(&encode_hex(&incarnation_bytes))
            .ok_or_else(|| anyhow::anyhow!("adopted incarnation is not a canonical UUIDv4"))?;
        let seed = decoder.blob()?.to_vec();
        decoder.finish()?;
        anyhow::ensure!(child_pid != 0 && session_id != 0, "adopted session is unnamed");
        let launch = HostLaunch {
            endpoint,
            record_path,
            term,
            cols,
            rows,
            cell_pixels,
            scrollback,
            cwd: None,
            command: Vec::new(),
            extra_env: Vec::new(),
            default_colors,
            kitty_graphics_limits,
            seed: Vec::new(),
        };
        Ok(Self { launch, child_pid, session_id, incarnation, seed })
    }
}

fn parse_fd(text: &str) -> Option<RawFd> {
    text.parse::<RawFd>().ok().filter(|fd| *fd > libc::STDERR_FILENO)
}

/// The adopted PTY descriptor of the hidden host's arguments, if any.
pub(super) fn adopt_pty_fd(args: &[String]) -> anyhow::Result<Option<RawFd>> {
    match args {
        [mode] if mode == "--bootstrap-stdio" => Ok(None),
        [mode, flag, fd] if mode == "--bootstrap-stdio" && flag == ADOPT_PTY_FD_FLAG => {
            parse_fd(fd).map(Some).ok_or_else(|| anyhow::anyhow!("invalid {ADOPT_PTY_FD_FLAG}"))
        }
        _ => anyhow::bail!("hidden mode requires --bootstrap-stdio"),
    }
}

/// The adopted descriptor named by this process's own arguments, for the
/// descriptor isolation that runs before argument dispatch.
pub(super) fn adopt_pty_fd_from_process_args() -> Option<RawFd> {
    // args_os: a non-UTF-8 executable path must not panic the host.
    let args = std::env::args_os().collect::<Vec<_>>();
    args.windows(2)
        .find(|pair| pair[0] == ADOPT_PTY_FD_FLAG)
        .and_then(|pair| pair[1].to_str().and_then(parse_fd))
}

/// Both `Launch` (with its optional respawn seed, cx-6so.49 L2) and
/// `LaunchAdopt` may carry a seed blob on top of the launch budget.
pub(super) fn max_payload(_adopt_fd: Option<RawFd>) -> usize {
    MAX_LAUNCH_ADOPT_PAYLOAD
}

/// Decode the private-pipe launch frame. An adopting host takes the
/// incarnation it adopts in place of the one `Bootstrap` drew.
pub(super) fn decode(
    frame: &Frame,
    adopt_fd: Option<RawFd>,
    bootstrapped: &mut crate::terminal_host::BootstrappedHost,
) -> anyhow::Result<(HostLaunch, Option<AdoptSpec>)> {
    let Some(fd) = adopt_fd else {
        if frame.kind != MessageKind::Launch {
            anyhow::bail!("expected terminal-host Launch, received {:?}", frame.kind);
        }
        return Ok((HostLaunch::decode(&frame.payload)?, None));
    };
    if frame.kind != MessageKind::LaunchAdopt {
        anyhow::bail!("expected terminal-host LaunchAdopt, received {:?}", frame.kind);
    }
    let adopt = HostLaunchAdopt::decode(&frame.payload)?;
    bootstrapped.incarnation = adopt.incarnation;
    let spec = AdoptSpec {
        fd,
        child_pid: adopt.child_pid,
        session_id: adopt.session_id,
        seed: adopt.seed,
    };
    Ok((adopt.launch, Some(spec)))
}

/// Take the incarnation's PTY ownership lock, then start the runtime on a
/// new child or on the adopted session. The lock is held for the process
/// lifetime; failing to take it is a launch failure.
pub(super) fn start(
    launch: &HostLaunch,
    adopt: Option<AdoptSpec>,
    bootstrapped: &crate::terminal_host::BootstrappedHost,
) -> anyhow::Result<(Arc<HostShared>, PtyOwnershipLock)> {
    let record_path = Path::new(&launch.record_path);
    if let Some(parent) = record_path.parent() {
        prepare_private_dir(parent)?;
    }
    let lock = PtyOwnershipLock::acquire(
        record_path,
        &bootstrapped.terminal_id.to_hex(),
        &bootstrapped.incarnation.to_hex(),
    )?;
    let shared = match adopt {
        None => spawn_host_runtime(launch, bootstrapped)?,
        Some(spec) => spawn_adopted_runtime(launch, bootstrapped, spec)?,
    };
    Ok((shared, lock))
}

fn spawn_adopted_runtime(
    launch: &HostLaunch,
    bootstrapped: &crate::terminal_host::BootstrappedHost,
    spec: AdoptSpec,
) -> anyhow::Result<Arc<HostShared>> {
    let child = AdoptedChild::adopt(spec.child_pid, spec.session_id)?;
    // SAFETY: the descriptor was named on this host's command line, kept
    // open by descriptor isolation, and is owned by nothing else here.
    let fd = unsafe { OwnedFd::from_raw_fd(spec.fd) };
    let master = cmux_pty::adopt_master(fd)?;
    let cell_pixels = (launch.cell_pixels.0.max(1), launch.cell_pixels.1.max(1));
    master.resize(pty_size(launch.cols, launch.rows, cell_pixels)?)?;
    crate::debug_spans::mark("host.pty_adopted");
    host_start::start_host_runtime(
        launch,
        bootstrapped,
        master,
        HostChild::Adopted(child),
        &spec.seed,
    )
}

/// What a replacement host adopts and how it presents the terminal.
pub struct TerminalHostAdoption<'a> {
    /// The PTY master and session taken with
    /// [`super::request_terminal_host_pty_custody`].
    pub custody: &'a PtyCustody,
    /// The dead host's terminal id and incarnation, both reused.
    pub identity: TerminalHostIdentity,
    /// The terminal's durable owner token, reused.
    pub owner_token: CapabilityToken,
    /// Terminal type, geometry and scrollback (command, cwd and environment
    /// are ignored: no child is spawned).
    pub options: &'a SurfaceOptions,
    pub default_colors: DefaultColors,
    pub cell_pixels: (u16, u16),
    pub kitty_graphics_limits: KittyGraphicsLimits,
    /// VT replay of the terminal's screen (the owner's mirror), applied to
    /// the new host's parser only. May be empty.
    pub seed: &'a [u8],
    /// The terminal-host binary; `None` runs this executable (tests pass the
    /// daemon binary).
    pub host_binary: Option<PathBuf>,
}

fn spawn_adopting_host(
    binary: PathBuf,
    master: RawFd,
) -> anyhow::Result<(SpawnedHostProcess, ChildStdinPair)> {
    let mut command = Command::new(binary);
    command
        .args(["__terminal-host", "--bootstrap-stdio", ADOPT_PTY_FD_FLAG])
        .arg(ADOPTED_PTY_FD.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    // SAFETY: setsid, dup2 and fcntl are async-signal-safe and touch no Rust
    // state in the post-fork child. The master stays open in the child until
    // exec; dup2 clears close-on-exec on the copy at the fixed descriptor.
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() < 0 {
                return Err(std_io::Error::last_os_error());
            }
            let placed = if master == ADOPTED_PTY_FD {
                libc::fcntl(master, libc::F_SETFD, 0)
            } else {
                libc::dup2(master, ADOPTED_PTY_FD)
            };
            if placed < 0 { Err(std_io::Error::last_os_error()) } else { Ok(()) }
        });
    }
    let child = command.spawn().context("spawn adopting terminal-host process")?;
    let mut process = SpawnedHostProcess { child: Some(child) };
    host_scope::place_host(process.child_mut().id());
    let stdin = process.child_mut().stdin.take().context("open terminal-host bootstrap stdin")?;
    let stdout =
        process.child_mut().stdout.take().context("open terminal-host bootstrap stdout")?;
    Ok((process, (stdin, stdout)))
}

type ChildStdinPair = (std::process::ChildStdin, std::process::ChildStdout);

/// The record of the host being replaced, if one is still published. It
/// must name the adopted incarnation. Whether that host is gone is decided
/// by the replacement's PTY ownership lock, not here: the kernel releases
/// it only when the old process is really gone.
fn predecessor(
    record_path: &Path,
    identity: &TerminalHostIdentity,
) -> anyhow::Result<Option<TerminalHostRecord>> {
    let bytes = match fs::read(record_path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std_io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let record: TerminalHostRecord = serde_json::from_slice(&bytes)?;
    validate_terminal_host_record(record_path, &record)?;
    anyhow::ensure!(
        record.terminal_id == identity.terminal_id && record.incarnation == identity.incarnation,
        "terminal-host record belongs to another incarnation"
    );
    Ok(Some(record))
}

/// Start a replacement host on the PTY in `adoption.custody`, reusing the
/// terminal id, incarnation and owner token. Returns its committed,
/// activated owner attachment; dropping it never ends the host.
pub fn launch_terminal_host_adopting(
    root: &Path,
    adoption: TerminalHostAdoption<'_>,
) -> anyhow::Result<HostAttachment> {
    let terminal_id = TerminalId::from_hex(&adoption.identity.terminal_id)
        .ok_or_else(|| anyhow::anyhow!("terminal id is not a canonical UUIDv4"))?;
    let incarnation = HostIncarnation::from_hex(&adoption.identity.incarnation)
        .ok_or_else(|| anyhow::anyhow!("incarnation is not a canonical UUIDv4"))?;
    let terminal_hex = terminal_id.to_hex();
    let launch_publication_lock = reserve_terminal_host_publication(root)?;
    let uid = fs::metadata(root)?.uid();
    let endpoint_root = PathBuf::from("/tmp").join(format!("cmux-th-{uid}"));
    prepare_endpoint_dir(&endpoint_root)?;
    let endpoint = endpoint_root.join(format!("{terminal_hex}.sock"));
    let record_path =
        crate::platform::normalize_filesystem_path(root.join(format!("{terminal_hex}.json")));
    let predecessor = predecessor(&record_path, &adoption.identity)?;
    let options = adoption.options;
    let launch = HostLaunchAdopt {
        launch: HostLaunch {
            endpoint: endpoint.to_string_lossy().into_owned(),
            record_path: record_path.to_string_lossy().into_owned(),
            term: options.term.clone(),
            cols: options.cols,
            rows: options.rows,
            cell_pixels: adoption.cell_pixels,
            scrollback: options.scrollback,
            cwd: None,
            command: Vec::new(),
            extra_env: Vec::new(),
            default_colors: adoption.default_colors,
            kitty_graphics_limits: adoption.kitty_graphics_limits,
            seed: Vec::new(),
        },
        child_pid: adoption.custody.child_pid,
        session_id: adoption.custody.session_id,
        incarnation,
        seed: adoption.seed.to_vec(),
    };
    let payload = launch.encode()?;
    let binary = match adoption.host_binary {
        Some(binary) => binary,
        None => crate::platform::self_exe_for_spawn()
            .context("resolve cmux-tui terminal-host binary")?,
    };
    let (process, (mut stdin, mut stdout)) =
        spawn_adopting_host(binary, adoption.custody.master.as_raw_fd())?;
    let host_pid = process.child.as_ref().map_or(0, std::process::Child::id);

    let bootstrap = HostBootstrap {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        terminal_id,
        owner_token: adoption.owner_token,
    };
    write_frame(&mut stdin, &bootstrap.into_frame(1))?;
    let ready_frame = read_required_frame(&mut stdout, "bootstrap ready")?;
    anyhow::ensure!(
        ready_frame.kind == MessageKind::Ready,
        "terminal host returned {:?} instead of Ready",
        ready_frame.kind
    );
    anyhow::ensure!(
        HostReady::decode(&ready_frame.payload)?.terminal_id == terminal_id,
        "terminal host changed terminal identity during bootstrap"
    );
    let mut launch_frame = Frame::new(MessageKind::LaunchAdopt, payload);
    launch_frame.request_id = 2;
    write_frame(&mut stdin, &launch_frame)?;
    let launched_frame = read_required_frame(&mut stdout, "adopt launch ready")?;
    anyhow::ensure!(launched_frame.request_id == 2, "terminal host did not acknowledge adoption");
    if launched_frame.kind == MessageKind::LaunchFailed {
        return Err(decode_host_launch_failure(&launched_frame.payload)?.into());
    }
    anyhow::ensure!(
        launched_frame.kind == MessageKind::Ready,
        "terminal host did not acknowledge adoption"
    );
    let launched = HostReady::decode(&launched_frame.payload)?;
    anyhow::ensure!(
        launched.terminal_id == terminal_id && launched.incarnation == incarnation,
        "replacement terminal host did not take the adopted identity"
    );
    drop(stdin);
    drop(stdout);

    let record: TerminalHostRecord = serde_json::from_slice(
        &fs::read(&record_path).context("read replacement terminal-host record")?,
    )?;
    validate_terminal_host_record(&record_path, &record)?;
    if record.terminal_id != terminal_hex
        || record.incarnation != adoption.identity.incarnation
        || record.owner_token != encode_hex(adoption.owner_token.as_bytes())
        || record.host_pid != host_pid
    {
        anyhow::bail!("replacement terminal-host record changed during launch");
    }
    drop(launch_publication_lock);
    // The dead host's liveness proof names its own nonce; nothing else
    // removes it once its record was replaced.
    if let Some(dead) = predecessor
        && dead.host_start_nonce != record.host_start_nonce
        && terminal_host_record_liveness(&record_path, &dead).ok()
            == Some(TerminalHostLiveness::Dead)
    {
        let _ = fs::remove_file(liveness_path(&record_path, &dead));
    }
    let mut attachment = connect_record(record, record_path, OwnerIntent::Surface)?;
    attachment.launch_process = Some(process);
    // The terminal's topology already exists: commit the handoff and
    // release the launch barrier at once.
    attachment.commit_launched_host();
    attachment.activate_launched_host()?;
    Ok(attachment)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adopt_launch(seed: Vec<u8>) -> HostLaunchAdopt {
        HostLaunchAdopt {
            launch: HostLaunch {
                endpoint: "/tmp/cmux-th-1/a.sock".into(),
                record_path: "/state/a.json".into(),
                term: "xterm-256color".into(),
                cols: 100,
                rows: 30,
                cell_pixels: (9, 18),
                scrollback: 4096,
                cwd: None,
                command: Vec::new(),
                extra_env: Vec::new(),
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
                seed: Vec::new(),
            },
            child_pid: 4242,
            session_id: 4242,
            incarnation: HostIncarnation::random().unwrap(),
            seed,
        }
    }

    #[test]
    fn launch_adopt_payload_round_trips_with_its_seed() {
        let launch = adopt_launch(b"\x1b[2Jseeded screen".to_vec());
        let decoded = HostLaunchAdopt::decode(&launch.encode().unwrap()).unwrap();
        assert_eq!(decoded.launch.endpoint, launch.launch.endpoint);
        assert_eq!(decoded.launch.record_path, launch.launch.record_path);
        assert_eq!((decoded.launch.cols, decoded.launch.rows), (100, 30));
        assert_eq!(decoded.launch.cell_pixels, (9, 18));
        assert_eq!(decoded.launch.scrollback, 4096);
        assert!(decoded.launch.command.is_empty() && decoded.launch.cwd.is_none());
        assert_eq!((decoded.child_pid, decoded.session_id), (4242, 4242));
        assert_eq!(decoded.incarnation, launch.incarnation);
        assert_eq!(decoded.seed, launch.seed);
        let empty = adopt_launch(Vec::new());
        assert!(HostLaunchAdopt::decode(&empty.encode().unwrap()).unwrap().seed.is_empty());
    }

    #[test]
    fn launch_adopt_payload_enforces_its_bounds() {
        let payload = adopt_launch(b"seed".to_vec()).encode().unwrap();
        let mut trailing = payload.clone();
        trailing.push(0);
        assert!(HostLaunchAdopt::decode(&trailing).is_err(), "trailing byte");
        assert!(HostLaunchAdopt::decode(&payload[..payload.len() - 1]).is_err(), "truncated");
        assert!(adopt_launch(vec![0; MAX_BLOB + 1]).encode().is_err(), "oversized seed");
        let full = adopt_launch(vec![b'x'; MAX_BLOB]).encode().unwrap();
        assert!(full.len() <= MAX_LAUNCH_ADOPT_PAYLOAD && full.len() > MAX_LAUNCH_PAYLOAD);
        assert_eq!(HostLaunchAdopt::decode(&full).unwrap().seed.len(), MAX_BLOB);
        let mut unnamed = adopt_launch(Vec::new());
        unnamed.child_pid = 0;
        assert!(unnamed.encode().is_err(), "zero child pid");
        // A non-UUIDv4 incarnation (all zero bytes) is rejected on decode.
        let mut zero = adopt_launch(Vec::new()).encode().unwrap();
        let at = zero.len() - 4 - 16;
        zero[at..at + 16].fill(0);
        assert!(HostLaunchAdopt::decode(&zero).is_err(), "bad incarnation");
    }

    #[test]
    fn launch_adopt_arguments_name_one_inherited_descriptor() {
        let args = |list: &[&str]| list.iter().map(|arg| (*arg).to_string()).collect::<Vec<_>>();
        assert_eq!(adopt_pty_fd(&args(&["--bootstrap-stdio"])).unwrap(), None);
        assert_eq!(
            adopt_pty_fd(&args(&["--bootstrap-stdio", "--adopt-pty-fd", "3"])).unwrap(),
            Some(3)
        );
        for bad in [
            &["--bootstrap-stdio", "--adopt-pty-fd", "2"][..],
            &["--bootstrap-stdio", "--adopt-pty-fd", "x"],
            &["--adopt-pty-fd", "3"],
            &["--bootstrap-stdio", "--adopt-pty-fd"],
            &[],
        ] {
            assert!(adopt_pty_fd(&args(bad)).is_err(), "{bad:?}");
        }
        assert_eq!(max_payload(None), MAX_LAUNCH_ADOPT_PAYLOAD, "a Launch may carry a seed");
        assert_eq!(max_payload(Some(3)), MAX_LAUNCH_ADOPT_PAYLOAD);
    }
}
