//! What this binary tells a client about itself and how it installs itself:
//! `remote-probe` and its capabilities, `remote-update-need`, and `install-self`.

use super::*;

/// Advertised by `remote-probe --json` so a control plane can choose routes the client can use.
///
/// `direct-ws-user-agent`: direct WebSocket dials carry a User-Agent, which
/// hosted ingress on branded machine domains requires.
/// `wireguard-hub`: `remote connect --wireguard-hub` and `wg hub` exist, so the
/// app may reach private-network machines through a shared in-process tunnel.
/// `wireguard-hub-token`: `wg hub --client-token-stdin` and `--config -`, and
/// `remote connect --wireguard-hub-token-stdin`, so only the app's own clients
/// use the hub and its config needs no file.
/// `remote-link-mux-socket` and `remote-link-strict-flags`: see
/// `cmux_remote::provider::REMOTE_LINK_MUX_SOCKET_CAPABILITY`; an SSH client
/// that needs one refuses a remote without it (cx-z3zh).
/// `cloud-browser-network`: Cloud browser proxy routes preserve the guest
/// machine's network and loopback context.
/// `ssh-payload-download` and `ssh-payload-macos-from-client`: see
/// `cmux_remote::SSH_PAYLOAD_DOWNLOAD_CAPABILITY` and
/// `cmux_remote::SSH_PAYLOAD_MACOS_FROM_CLIENT_CAPABILITY`.
pub const PROBE_CAPABILITIES: &[&str] = &[
    "direct-ws-user-agent",
    "wireguard-hub",
    "wireguard-hub-token",
    "browser-proxy",
    "cloud-browser-network",
    cmux_remote::provider::REMOTE_LINK_MUX_SOCKET_CAPABILITY,
    cmux_remote::provider::REMOTE_LINK_STRICT_FLAGS_CAPABILITY,
    cmux_remote::SSH_PAYLOAD_DOWNLOAD_CAPABILITY,
    cmux_remote::SSH_PAYLOAD_MACOS_FROM_CLIENT_CAPABILITY,
];

/// `remote update-need --probe-json <file|->` (cx-3r9mt): whether the machine
/// whose `remote-probe --json` this is runs an older, the same or a newer
/// cmux-tui than this binary, by `cmux_remote::update_need`. Exit 0 for every
/// answer; only bad input fails.
pub(super) fn run_update_need(args: &[String]) -> anyhow::Result<()> {
    use cmux_remote::update_need::{BuildFacts, update_need};
    let source = match args {
        [flag, source] if flag == "--probe-json" => source.as_str(),
        [single] if single.starts_with("--probe-json=") => &single["--probe-json=".len()..],
        _ => return Err(anyhow!(catalog().remote.remote_update_need_help)),
    };
    let text = if source == "-" {
        let mut text = String::new();
        io::stdin().read_to_string(&mut text).context("read the probe JSON from stdin")?;
        text
    } else {
        fs::read_to_string(source).with_context(|| format!("read {source}"))?
    };
    let probe: Value = serde_json::from_str(&text).context("the probe is not JSON")?;
    let object = probe.as_object().ok_or_else(|| anyhow!("the probe is not a JSON object"))?;
    let remote = BuildFacts {
        commit: object.get("build_identity").and_then(Value::as_str).map(str::to_owned),
        time: object.get("build_time").and_then(Value::as_u64).unwrap_or(0),
        capabilities: object
            .get("daemon_capabilities")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect()),
    };
    let local = BuildFacts {
        commit: Some(BUILD_IDENTITY.to_owned()),
        time: cmux_build_identity::BUILD_TIME,
        capabilities: Some(
            cmux_tui_core::server::build_capabilities().into_iter().map(str::to_owned).collect(),
        ),
    };
    let (need, reason) = update_need(&local, &remote);
    let side = |facts: &BuildFacts| {
        serde_json::json!({
            "commit": facts.commit,
            "time": facts.time,
            "capabilities_count": facts.capabilities.as_ref().map(BTreeSet::len),
        })
    };
    let mut answer = serde_json::json!({
        "need": need, "reason": reason, "remote": side(&remote), "local": side(&local),
    });
    if reason == cmux_remote::update_need::Reason::Incomparable {
        answer.set(
            "warning",
            serde_json::json!(
                "each build serves a capability the other lacks; neither replaces the other"
            ),
        );
    }
    println!("{answer}");
    Ok(())
}

pub(super) fn run_probe(args: &[String]) -> anyhow::Result<()> {
    let value = serde_json::json!({
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "distribution_version": DISTRIBUTION_VERSION,
        "npm_bootstrap_version": NPM_BOOTSTRAP_VERSION,
        "build_identity": BUILD_IDENTITY,
        // cx-3r9mt: what `remote update-need` orders builds by.
        "build_time": cmux_build_identity::BUILD_TIME,
        "remote_protocol": REMOTE_PROTOCOL_VERSION,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        // Client-side transport capabilities a control plane can key routing on.
        "capabilities": PROBE_CAPABILITIES,
    });
    // The capability list only on request: the SSH bootstrap of every client reads at most
    // 4096 bytes of this output, and the list alone is larger (cx-3r9mt).
    let mut value = value;
    if args.iter().any(|argument| argument == "--build-facts") {
        value.set(
            "daemon_capabilities",
            serde_json::json!(cmux_tui_core::server::build_capabilities()),
        );
    }
    if args.iter().any(|argument| argument == "--json") {
        println!("{}", serde_json::to_string(&value)?);
    } else {
        println!(
            "cmux-tui {} remote-protocol={} {}-{}",
            env!("CARGO_PKG_VERSION"),
            REMOTE_PROTOCOL_VERSION,
            std::env::consts::OS,
            std::env::consts::ARCH
        );
    }
    Ok(())
}

struct PendingInstall {
    parent_fd: std::os::fd::RawFd,
    name: std::ffi::CString,
    armed: bool,
}

impl Drop for PendingInstall {
    fn drop(&mut self) {
        if self.armed {
            unsafe {
                libc::unlinkat(self.parent_fd, self.name.as_ptr(), 0);
            }
        }
    }
}

fn install_path_component(
    component: &std::ffi::OsStr,
    description: &str,
) -> anyhow::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt as _;

    std::ffi::CString::new(component.as_bytes())
        .with_context(|| format!("{description} contains a NUL byte"))
}

fn open_install_parent(path: &Path) -> anyhow::Result<std::os::fd::OwnedFd> {
    use std::os::fd::FromRawFd as _;
    use std::os::unix::ffi::OsStrExt as _;

    let encoded = std::ffi::CString::new(path.as_os_str().as_bytes())
        .context("install parent contains a NUL byte")?;
    let descriptor = unsafe {
        libc::open(
            encoded.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error()).context("could not open install parent");
    }
    // SAFETY: `open` returned a new owned descriptor.
    let descriptor = unsafe { std::os::fd::OwnedFd::from_raw_fd(descriptor) };
    let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(descriptor.as_raw_fd(), status.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error()).context("could not inspect install parent");
    }
    // SAFETY: `fstat` initialized the structure on success.
    let status = unsafe { status.assume_init() };
    if status.st_uid != unsafe { libc::geteuid() } || status.st_mode & 0o022 != 0 {
        return Err(anyhow!(
            "install parent must be owned by the current user and not group or world writable"
        ));
    }
    Ok(descriptor)
}

pub(super) fn run_install_self(args: &[String]) -> anyhow::Result<()> {
    use std::os::fd::FromRawFd as _;

    let destination = flag_value(args, "--destination")
        .map(expand_home)
        .transpose()?
        .ok_or_else(|| anyhow!("install-self needs --destination"))?;
    let source = std::env::current_exe()?;
    let parent = destination.parent().ok_or_else(|| anyhow!("destination has no parent"))?;
    let parent = if parent.as_os_str().is_empty() { Path::new(".") } else { parent };
    let destination_name =
        destination.file_name().ok_or_else(|| anyhow!("destination has no file name"))?;
    if destination_name == "." || destination_name == ".." {
        return Err(anyhow!("destination has an invalid file name"));
    }
    let destination_name = install_path_component(destination_name, "destination file name")?;
    fs::create_dir_all(parent)?;
    let parent = open_install_parent(parent)?;
    let temporary_name =
        std::ffi::CString::new(format!(".cmux-tui-install-{}", uuid::Uuid::new_v4()))
            .expect("UUID staging name has no NUL bytes");
    let temporary_descriptor = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            temporary_name.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if temporary_descriptor < 0 {
        return Err(io::Error::last_os_error()).context("could not create staged install");
    }
    // SAFETY: `openat` returned a new owned descriptor.
    let mut temporary = unsafe { fs::File::from_raw_fd(temporary_descriptor) };
    let mut pending =
        PendingInstall { parent_fd: parent.as_raw_fd(), name: temporary_name, armed: true };
    let mut source_file =
        fs::File::open(&source).with_context(|| format!("could not open {}", source.display()))?;
    io::copy(&mut source_file, &mut temporary)
        .with_context(|| format!("could not copy {}", source.display()))?;
    temporary.flush().context("could not flush staged install")?;
    temporary.sync_all().context("could not sync staged install")?;
    if unsafe { libc::fchmod(temporary.as_raw_fd(), 0o755) } != 0 {
        return Err(io::Error::last_os_error()).context("could not set staged install permissions");
    }
    temporary.sync_all().context("could not sync staged install permissions")?;
    if unsafe {
        libc::renameat(
            parent.as_raw_fd(),
            pending.name.as_ptr(),
            parent.as_raw_fd(),
            destination_name.as_ptr(),
        )
    } != 0
    {
        return Err(io::Error::last_os_error()).context("could not install remote binary");
    }
    pending.armed = false;
    if unsafe { libc::fsync(parent.as_raw_fd()) } != 0 {
        return Err(io::Error::last_os_error()).context("could not sync install parent");
    }
    println!("{}", destination.display());
    Ok(())
}
