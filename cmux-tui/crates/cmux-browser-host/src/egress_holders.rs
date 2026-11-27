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
    /// The process id (Linux keys the DevTools probe by it; macOS by the
    /// listener's pid).
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub(crate) pid: i32,
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
/// `ws://localhost:9333/path`, any of them in double quotes. `None`: no port
/// given; `Some(0)`: picked by the system.
fn value_port(value: &str) -> Option<u16> {
    let value = value.trim_matches('"');
    let value = value.split_once("://").map_or(value, |(_, rest)| rest);
    let value = value.split('/').next().unwrap_or(value);
    if let Ok(port) = value.parse() {
        return Some(port);
    }
    value.rsplit_once(':').and_then(|(_, port)| port.parse().ok())
}

/// An option name as Node and Chromium match it: `_` reads as `-`, and
/// Chromium takes a single leading dash too.
fn option_name(flag: &str) -> String {
    let flag = flag.replace('_', "-");
    if flag.starts_with('-') && !flag.starts_with("--") { format!("-{flag}") } else { flag }
}

/// The debugger ports opened by `args` (`--inspect` forms, `--debug`
/// forms, `--remote-debugging-port`); `None` when there are none.
fn args_debug_ports<S: AsRef<str>>(args: &[S]) -> Option<DebugPorts> {
    let mut ports = Vec::new();
    let mut found = false;
    let mut unknown = false;
    for (at, arg) in args.iter().enumerate() {
        let arg = arg.as_ref();
        let (flag, value) = match arg.split_once('=') {
            Some((flag, value)) => (flag, Some(value)),
            None => (arg, None),
        };
        let flag = option_name(flag);
        let port_flag =
            matches!(flag.as_str(), "--inspect-port" | "--debug-port" | "--remote-debugging-port");
        let opens = port_flag
            || ["--inspect", "--inspect-brk", "--inspect-brk-node", "--inspect-wait"]
                .contains(&flag.as_str())
            || ["--debug", "--debug-brk"].contains(&flag.as_str());
        if !opens {
            continue;
        }
        found = true;
        // A port flag may take its value as the next argument.
        let value =
            value.or_else(|| port_flag.then(|| args.get(at + 1).map(AsRef::as_ref)).flatten());
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

/// `NODE_OPTIONS` split as Node splits it: on spaces, with double quotes
/// grouping and a backslash escaping inside them.
fn node_options(value: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut word = String::new();
    let (mut quoted, mut escaped, mut started) = (false, false, false);
    for c in value.chars() {
        if escaped {
            word.push(c);
            escaped = false;
        } else if quoted && c == '\\' {
            escaped = true;
        } else if c == '"' {
            quoted = !quoted;
            started = true;
        } else if c.is_whitespace() && !quoted {
            if started || !word.is_empty() {
                out.push(std::mem::take(&mut word));
            }
            started = false;
        } else {
            word.push(c);
        }
    }
    if started || !word.is_empty() {
        out.push(word);
    }
    out
}

/// The debugger ports a process opened, from its arguments and its
/// environment; `None` when it opened none.
fn debug_ports(holder: &Holder) -> Option<DebugPorts> {
    let mut found = vec![args_debug_ports(&holder.args)];
    for entry in &holder.env {
        let Some((name, value)) = entry.split_once('=') else { continue };
        found.push(match name {
            "NODE_OPTIONS" => args_debug_ports(&node_options(value)),
            // A Unix socket opens no TCP port.
            "BUN_INSPECT" if value.starts_with("ws+unix:") => None,
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

/// Whether the holder is node, bun or deno (a versioned name such as
/// `node22` too, and a deleted binary): a runtime that can open a V8
/// inspector with no flag. Its executable path does not change with
/// `process.title`.
pub(crate) fn is_inspector_runtime(holder: &Holder) -> bool {
    let path = holder.path.as_str();
    let name = path.rsplit('/').next().unwrap_or(path);
    let name = name.strip_suffix(" (deleted)").unwrap_or(name);
    INSPECTOR_RUNTIMES.iter().any(|runtime| {
        name.strip_prefix(runtime).is_some_and(|rest| rest.bytes().all(|b| b.is_ascii_digit()))
    })
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
    (is_inspector_runtime(holder) && DEFAULT_INSPECTOR_PORTS.contains(&port))
        .then(|| format!("loopback port {port} is the default inspector port of {name}"))
}

/// Frameworks that make an app bundle Chromium-based.
const CHROMIUM_FRAMEWORKS: &[&str] =
    &["Electron Framework.framework", "Chromium Embedded Framework.framework"];

/// Whether an app bundle ships Chromium: Electron or CEF, or V8's snapshot
/// in one of its frameworks (Chrome, Arc, Dia, Vivaldi, Opera).
fn ships_chromium(app: &std::path::Path) -> bool {
    let frameworks = app.join("Contents/Frameworks");
    if CHROMIUM_FRAMEWORKS.iter().any(|f| frameworks.join(f).exists()) {
        return true;
    }
    let Ok(entries) = std::fs::read_dir(&frameworks) else { return false };
    entries.flatten().any(|framework| {
        let Ok(versions) = std::fs::read_dir(framework.path().join("Versions")) else {
            return false;
        };
        versions.flatten().any(|version| {
            std::fs::read_dir(version.path().join("Resources")).is_ok_and(|files| {
                files.flatten().any(|file| {
                    file.file_name().to_string_lossy().starts_with("v8_context_snapshot")
                })
            })
        })
    })
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
/// macOS: whether the executable at `path` is an app's own executable (in
/// some `X.app/Contents/MacOS/`) inside an app bundle, at any depth (helpers
/// live inside the app's frameworks), that ships Chromium. A tool in an
/// app's `Resources` (Rancher Desktop's port forwarder) is not.
pub(crate) fn bundle_is_chromium_family(path: &str) -> bool {
    let path = std::path::Path::new(path);
    let mut up = path.ancestors().skip(1);
    let own_executable = matches!(
        (up.next(), up.next(), up.next()),
        (Some(macos), Some(contents), Some(app))
            if macos.file_name().is_some_and(|n| n == "MacOS")
                && contents.file_name().is_some_and(|n| n == "Contents")
                && app.extension().is_some_and(|e| e == "app")
    );
    own_executable
        && path
            .ancestors()
            .filter(|p| p.extension().is_some_and(|e| e == "app"))
            .any(ships_chromium)
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
    // `process.title` pads the argument area with NULs: skip them.
    let env = strings
        .skip_while(|s| s.is_empty())
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
    Some(Holder { pid, path, args, env })
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
    let pid = pid.parse().ok()?;
    Some(Holder { pid, path: path.to_string_lossy().into_owned(), args, env })
}

#[cfg(test)]
#[path = "egress_holders_tests.rs"]
mod tests;
