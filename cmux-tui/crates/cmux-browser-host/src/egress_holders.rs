//! What the process that holds a loopback listener is, for the egress
//! service check (crate::egress_services, crate::egress_listeners). A port
//! is refused when its holder:
//!
//! - is a cmux service or a Chrome-like browser by name
//!   (crate::egress_services::is_service_name, `is_app_service_name`);
//! - belongs to the Chromium family by what it ships (`family`: an Electron
//!   or CEF app such as VS Code, Cursor or Slack, any of whose processes can
//!   serve a DevTools port);
//! - opened a code-execution port on that port: `--inspect` and its forms,
//!   `--debug`, `--remote-debugging-port`, in its arguments or in
//!   `NODE_OPTIONS`, or `BUN_INSPECT`. A flag whose port the system picks
//!   (`=0`) or that this host cannot read refuses every port of the process;
//! - is node, bun or deno on a default inspector port (9229, 6499), which
//!   SIGUSR1 opens without any flag.
//!
//! The dev server port of a process that also runs an inspector on another
//! known port stays allowed (`next dev --inspect` keeps working).

/// The process that holds a listener.
#[derive(Clone, Debug, Default)]
pub(crate) struct Holder {
    /// The executable path.
    pub(crate) path: String,
    pub(crate) args: Vec<String>,
    /// `NAME=value` entries.
    pub(crate) env: Vec<String>,
}

/// The default inspector ports: node and deno (9229), bun (6499).
const DEFAULT_INSPECTOR_PORTS: [u16; 2] = [9229, 6499];

/// Executables that open an inspector on SIGUSR1 or by default.
const INSPECTOR_RUNTIMES: &[&str] = &["node", "nodejs", "bun", "deno"];

/// The ports a process opened for a debugger.
#[derive(Debug, PartialEq)]
enum DebugPorts {
    Known(Vec<u16>),
    /// A debugger port whose number this host cannot tell.
    Unknown,
}

/// The port in a flag value: `9333`, `127.0.0.1:9333`, `[::1]:9333`,
/// `ws://localhost:9333/path`. `None`: no port given; `Some(0)`: picked by
/// the system.
fn value_port(value: &str) -> Option<u16> {
    let value = value.split_once("://").map_or(value, |(_, rest)| rest);
    let value = value.split('/').next().unwrap_or(value);
    if let Ok(port) = value.parse() {
        return Some(port);
    }
    value.rsplit_once(':').and_then(|(_, port)| port.parse().ok())
}

/// The debugger ports opened by `args` (`--inspect` forms, `--debug`
/// forms, `--remote-debugging-port`); `None` when there are none.
fn args_debug_ports<'a>(args: impl IntoIterator<Item = &'a str>) -> Option<DebugPorts> {
    let args: Vec<&str> = args.into_iter().collect();
    let mut ports = Vec::new();
    let mut found = false;
    let mut unknown = false;
    for (at, arg) in args.iter().enumerate() {
        let (flag, value) = match arg.split_once('=') {
            Some((flag, value)) => (flag, Some(value)),
            None => (*arg, None),
        };
        let port_flag =
            matches!(flag, "--inspect-port" | "--debug-port" | "--remote-debugging-port");
        let opens = port_flag
            || ["--inspect", "--inspect-brk", "--inspect-wait", "--debug", "--debug-brk"]
                .contains(&flag);
        if !opens {
            continue;
        }
        found = true;
        // A port flag may take its value as the next argument.
        let value = value.or_else(|| port_flag.then(|| args.get(at + 1).copied()).flatten());
        match value.map(value_port) {
            Some(Some(0)) => unknown = true,
            Some(Some(port)) => ports.push(port),
            // `--remote-debugging-port` without a number: unknown.
            Some(None) | None if port_flag => unknown = true,
            _ => ports.extend(DEFAULT_INSPECTOR_PORTS),
        }
    }
    if !found {
        return None;
    }
    Some(if unknown { DebugPorts::Unknown } else { DebugPorts::Known(ports) })
}

/// The debugger ports a process opened, from its arguments and its
/// environment; `None` when it opened none.
fn debug_ports(holder: &Holder) -> Option<DebugPorts> {
    let mut found = vec![args_debug_ports(holder.args.iter().map(String::as_str))];
    for entry in &holder.env {
        let Some((name, value)) = entry.split_once('=') else { continue };
        found.push(match name {
            "NODE_OPTIONS" => args_debug_ports(value.split_whitespace()),
            // A URL (`ws://host:port/prefix`) or a bare path prefix.
            "BUN_INSPECT" if !value.is_empty() => Some(match value_port(value) {
                Some(port) if port != 0 && value.contains("://") => DebugPorts::Known(vec![port]),
                _ => DebugPorts::Unknown,
            }),
            _ => None,
        });
    }
    let mut ports = Vec::new();
    for found in found.into_iter().flatten() {
        match found {
            DebugPorts::Unknown => return Some(DebugPorts::Unknown),
            DebugPorts::Known(known) => ports.extend(known),
        }
    }
    (!ports.is_empty()).then_some(DebugPorts::Known(ports))
}

/// Why a listener on `port` held by `holder` is refused, or `None`.
/// `family`: the holder belongs to the Chromium family (Electron, CEF).
pub(crate) fn holder_refusal(holder: &Holder, port: u16, family: bool) -> Option<String> {
    let path = holder.path.as_str();
    let name = path.rsplit('/').next().unwrap_or(path);
    if crate::egress_services::is_service_name(name)
        || crate::egress_services::is_app_service_name(name)
    {
        return Some(format!("loopback port {port} is the cmux service {name}"));
    }
    if family {
        return Some(format!(
            "loopback port {port} is held by {name}, a Chromium-based app that can serve DevTools"
        ));
    }
    match debug_ports(holder) {
        Some(DebugPorts::Unknown) => {
            return Some(format!(
                "loopback port {port} is held by {name}, which runs an inspector on a port this \
                 host cannot tell"
            ));
        }
        Some(DebugPorts::Known(ports)) if ports.contains(&port) => {
            return Some(format!("loopback port {port} is the inspector port of {name}"));
        }
        _ => {}
    }
    let runtime = INSPECTOR_RUNTIMES.iter().any(|runtime| {
        name == *runtime
            || name
                .strip_prefix(runtime)
                .is_some_and(|rest| rest.bytes().all(|b| b.is_ascii_digit()))
    });
    (runtime && DEFAULT_INSPECTOR_PORTS.contains(&port))
        .then(|| format!("loopback port {port} is the default inspector port of {name}"))
}

/// Frameworks that make an app bundle Chromium-based.
const CHROMIUM_FRAMEWORKS: &[&str] =
    &["Electron Framework.framework", "Chromium Embedded Framework.framework"];

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
/// macOS: whether the executable at `path` belongs to an app bundle that
/// ships Electron or CEF: its own bundle, or, for a helper app inside
/// `<App>.app/Contents/Frameworks`, that app.
pub(crate) fn bundle_is_chromium_family(path: &str) -> bool {
    let path = std::path::Path::new(path);
    let Some(bundle) = path.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")) else {
        return false;
    };
    let ships = |app: &std::path::Path| {
        CHROMIUM_FRAMEWORKS.iter().any(|f| app.join("Contents/Frameworks").join(f).exists())
    };
    if ships(bundle) {
        return true;
    }
    // A helper: <App>.app/Contents/Frameworks/<Helper>.app.
    let mut up = bundle.ancestors().skip(1);
    match (up.next(), up.next(), up.next()) {
        (Some(frameworks), Some(contents), Some(app))
            if frameworks.file_name().is_some_and(|n| n == "Frameworks")
                && contents.file_name().is_some_and(|n| n == "Contents")
                && app.extension().is_some_and(|e| e == "app") =>
        {
            ships(app)
        }
        _ => false,
    }
}

/// Linux: whether the executable at `path` sits beside Chromium's V8
/// snapshot, as Chrome, Chromium and every Electron app (VS Code, Cursor,
/// Slack) ship it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn dir_is_chromium_family(path: &str) -> bool {
    let Some(dir) = std::path::Path::new(path).parent() else { return false };
    ["v8_context_snapshot.bin", "snapshot_blob.bin"].iter().any(|f| dir.join(f).exists())
}

/// A `KERN_PROCARGS2` answer: `argc` (i32), the exec path, NUL padding,
/// `argc` arguments, then the environment, each NUL-terminated.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn parse_procargs2(data: &[u8]) -> Option<(Vec<String>, Vec<String>)> {
    let argc = i32::from_le_bytes(data.get(..4)?.try_into().ok()?);
    let argc = usize::try_from(argc).ok()?;
    let rest = &data[4..];
    let path_end = rest.iter().position(|b| *b == 0)?;
    let start = path_end + rest[path_end..].iter().position(|b| *b != 0)?;
    let mut strings = rest[start..].split(|b| *b == 0);
    let args: Vec<String> =
        strings.by_ref().take(argc).map(|s| String::from_utf8_lossy(s).into_owned()).collect();
    if args.len() != argc {
        return None;
    }
    let env = strings
        .take_while(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect();
    Some((args, env))
}

/// macOS: the holder `pid` (executable, arguments, environment); `None`
/// when it cannot be read.
#[cfg(target_os = "macos")]
pub(crate) fn system_holder(pid: i32) -> Option<Holder> {
    let path = crate::egress_services::executable_path(pid)?;
    let mut argmax: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: the out buffer is a c_int and `size` is its size.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            2,
            (&raw mut argmax).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 || argmax <= 0 {
        return None;
    }
    let mut buffer = vec![0u8; argmax as usize];
    let mut filled = buffer.len();
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    // SAFETY: the buffer is writable for `filled` bytes, which is passed.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buffer.as_mut_ptr().cast(),
            &mut filled,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return None;
    }
    let (args, env) = parse_procargs2(&buffer[..filled])?;
    Some(Holder { path, args, env })
}

/// Linux: the holder `pid` from `/proc`; `None` when it cannot be read.
#[cfg(target_os = "linux")]
pub(crate) fn system_holder(pid: &str) -> Option<Holder> {
    let path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let split = |bytes: Vec<u8>| -> Vec<String> {
        bytes
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .map(|s| String::from_utf8_lossy(s).into_owned())
            .collect()
    };
    let args = split(std::fs::read(format!("/proc/{pid}/cmdline")).ok()?);
    let env = split(std::fs::read(format!("/proc/{pid}/environ")).ok()?);
    Some(Holder { path: path.to_string_lossy().into_owned(), args, env })
}

#[cfg(test)]
#[path = "egress_holders_tests.rs"]
mod tests;
