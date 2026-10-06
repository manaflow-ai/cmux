//! `cmux-browser-host`: the browser host until `cmux browser host` exists in
//! the Rust cmux binary (#16174).
//!
//!   cmux-browser-host serve [--socket PATH]
//!   cmux-browser-host eval [--session NAME] [--engine E] [--max-output N] [--timeout-ms N] (-|CODE)
//!   cmux-browser-host list | close --session NAME | guide | version
//!
//! `eval` starts the host on demand when no host answers on the socket.
//! MCP clients use `cmux mcp serve` (one MCP entry point, cmux.json
//! mcp.enabled); this binary has no MCP server.
//!
//! The macOS app ships it as `Contents/Resources/bin/cmux-browser-host`,
//! beside `bin/cmux`: the daemon runs the sibling of its own executable
//! (scripts/cmux-next/bundle-cmux-tui.sh, check-bundled-browser-host.sh).

#[cfg(unix)]
fn main() {
    std::process::exit(unix::run(std::env::args().skip(1).collect()));
}

#[cfg(not(unix))]
fn main() {
    eprintln!("cmux-browser-host needs a Unix host");
    std::process::exit(2);
}

#[cfg(unix)]
mod unix {
    use cmux_browser_host::engines::HostEngines;
    use cmux_browser_host::host::{Host, agent_bundle, bundle};
    use cmux_browser_host::idle_exit::{IdleExit, SystemClock};
    use cmux_browser_host::server::{bind, default_socket_path, serve};
    use serde_json::{Value, json};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::os::unix::net::UnixStream;
    use std::os::unix::process::CommandExt;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    #[derive(Clone)]
    struct Options {
        socket: PathBuf,
        session: String,
        engine: String,
        max_output: Option<u64>,
        timeout_ms: Option<u64>,
        code: Option<String>,
        /// An inherited fd that carries the per-launch provider secret
        /// (the daemon writes it and closes its end). Never argv or env.
        provider_secret_fd: Option<i32>,
        /// Started by the daemon (`--supervised`): print `ready` on stdout
        /// once both sockets listen, and exit when stdin reaches its end
        /// (the daemon closed it or died), so no host outlives its daemon.
        supervised: bool,
        /// Listening sockets the daemon bound and keeps (socket activation:
        /// it starts the host again on the next agent connect).
        agent_listen_fd: Option<i32>,
        provider_listen_fd: Option<i32>,
        /// With `--supervised`: exit after this long with no session and no
        /// provider (the idle stop).
        idle_exit_ms: Option<u64>,
    }

    fn parse(args: &[String]) -> Result<Options, String> {
        let mut options = Options {
            socket: default_socket_path(),
            session: "default".into(),
            engine: std::env::var("CMUX_BROWSER_HOST_ENGINE").unwrap_or_else(|_| "auto".into()),
            max_output: None,
            timeout_ms: None,
            code: None,
            provider_secret_fd: None,
            supervised: false,
            agent_listen_fd: None,
            provider_listen_fd: None,
            idle_exit_ms: None,
        };
        let mut iter = args.iter();
        while let Some(arg) = iter.next() {
            let mut value =
                |name: &str| iter.next().cloned().ok_or_else(|| format!("{name} needs a value"));
            match arg.as_str() {
                "--socket" => options.socket = PathBuf::from(value("--socket")?),
                "--session" => options.session = value("--session")?,
                "--engine" => options.engine = value("--engine")?,
                "--max-output" => {
                    options.max_output = Some(
                        value("--max-output")?
                            .parse()
                            .map_err(|_| "--max-output: expected a number")?,
                    );
                }
                "--timeout-ms" => {
                    options.timeout_ms = Some(
                        value("--timeout-ms")?
                            .parse()
                            .map_err(|_| "--timeout-ms: expected a number")?,
                    );
                }
                "--provider-secret-fd" => {
                    options.provider_secret_fd = Some(
                        value("--provider-secret-fd")?
                            .parse()
                            .map_err(|_| "--provider-secret-fd: expected a file descriptor")?,
                    );
                }
                "--supervised" => options.supervised = true,
                "--agent-listen-fd" => {
                    options.agent_listen_fd = Some(
                        value("--agent-listen-fd")?
                            .parse()
                            .map_err(|_| "--agent-listen-fd: expected a file descriptor")?,
                    );
                }
                "--provider-listen-fd" => {
                    options.provider_listen_fd = Some(
                        value("--provider-listen-fd")?
                            .parse()
                            .map_err(|_| "--provider-listen-fd: expected a file descriptor")?,
                    );
                }
                "--idle-exit-ms" => {
                    options.idle_exit_ms = Some(
                        value("--idle-exit-ms")?
                            .parse()
                            .map_err(|_| "--idle-exit-ms: expected a number")?,
                    );
                }
                "-" => {
                    let mut code = String::new();
                    std::io::stdin()
                        .read_to_string(&mut code)
                        .map_err(|e| format!("stdin: {e}"))?;
                    options.code = Some(code);
                }
                other if other.starts_with("--") => return Err(format!("unknown option {other}")),
                other => options.code = Some(other.to_owned()),
            }
        }
        Ok(options)
    }

    pub fn run(args: Vec<String>) -> i32 {
        let Some((command, rest)) = args.split_first() else {
            eprintln!("usage: cmux-browser-host serve|eval|list|close|guide");
            return 2;
        };
        let options = match parse(rest) {
            Ok(options) => options,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                return 2;
            }
        };
        match command.as_str() {
            // `cmux-browser-host <version> (<build sha>)`, one line (release smoke check).
            "version" | "--version" => {
                println!(
                    "cmux-browser-host {} ({})",
                    env!("CARGO_PKG_VERSION"),
                    option_env!("CMUX_BUILD_SHA").unwrap_or("unknown")
                );
                0
            }
            "serve" => serve_command(&options),
            "guide" => {
                print!("{}", bundle::GUIDE);
                0
            }
            "eval" => eval_command(&options, rest.iter().any(|a| a == "--session")),
            "mcp" => {
                eprintln!(
                    "cmux-browser-host: no MCP server here; use `cmux mcp serve` (turn it on with \"mcp\": {{\"enabled\": true}} in cmux.json)"
                );
                2
            }
            "list" => simple(&options, "browser.repl.list", json!({})),
            "close" => simple(&options, "browser.repl.close", json!({"session": options.session})),
            other => {
                eprintln!("cmux-browser-host: unknown command {other}");
                2
            }
        }
    }

    /// Reads the per-launch secret from an inherited pipe (at most 4 KiB, to
    /// its end) and closes it.
    fn read_secret_fd(fd: i32) -> Result<String, String> {
        use std::os::fd::FromRawFd;
        if fd < 3 {
            return Err(format!("--provider-secret-fd {fd}: not an inherited descriptor"));
        }
        // SAFETY: fstat(2) on an fd number with a zeroed out buffer.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(fd, &mut stat) } != 0
            || (stat.st_mode & libc::S_IFMT) != libc::S_IFIFO
        {
            return Err(format!("--provider-secret-fd {fd}: not a pipe"));
        }
        // SAFETY: the daemon passes this pipe open for this process; it is read once and closed here.
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        let mut secret = String::new();
        file.take(4096).read_to_string(&mut secret).map_err(|e| format!("reading: {e}"))?;
        let secret = secret.trim().to_owned();
        if secret.len() < 32 {
            return Err("the provider secret is too short".into());
        }
        Ok(secret)
    }

    /// Serves the app's provider socket on its own thread.
    fn start_provider_listener(
        listener: std::os::unix::net::UnixListener,
        secret: String,
        engines: &HostEngines,
        on_change: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<(), String> {
        let slot = engines.provider_slot();
        let bundle: Arc<str> = agent_bundle().into();
        std::thread::Builder::new()
            .name("cmux-browser-host-providers".into())
            .spawn(move || {
                let secret = cmux_browser_host::provider::ProviderSecret::new(secret);
                let _ = cmux_browser_host::server::serve_providers_notifying(
                    listener, secret, slot, bundle, on_change,
                );
            })
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn inherited_listener(fd: i32, flag: &str) -> Result<std::os::unix::net::UnixListener, String> {
        cmux_browser_host::server::inherited_listener(fd).map_err(|error| format!("{flag} {error}"))
    }

    fn serve_command(options: &Options) -> i32 {
        // The secret fd is read before anything else is opened, so a wrong
        // fd number cannot take the socket or its lock file.
        let secret = match options.provider_secret_fd.map(read_secret_fd).transpose() {
            Ok(secret) => secret,
            Err(error) => {
                eprintln!("cmux-browser-host: provider secret: {error}");
                return 1;
            }
        };
        let owns_dir = std::env::var_os("CMUX_BROWSER_HOST_SOCKET").is_none_or(|p| p.is_empty());
        let listener = match options.agent_listen_fd {
            Some(fd) => inherited_listener(fd, "--agent-listen-fd"),
            None => bind(&options.socket, owns_dir).map_err(|error| error.to_string()),
        };
        let listener = match listener {
            Ok(listener) => listener,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                return 1;
            }
        };
        let cwd =
            std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_else(|_| "/".into());
        let engines = Arc::new(HostEngines::new(agent_bundle()));
        let host = Arc::new(Host::new(engines.clone(), cwd));
        let idle = options.idle_exit_ms.filter(|_| options.supervised).map(|ms| {
            let (probe_host, slot) = (Arc::downgrade(&host), engines.provider_slot());
            let busy = move || {
                let sessions = probe_host
                    .upgrade()
                    .is_some_and(|host| host.session_count() > 0 || host.connection_count() > 0);
                let provider = slot
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .as_ref()
                    .is_some_and(|provider| provider.closed_reason().is_none());
                sessions || provider
            };
            IdleExit::new(Duration::from_millis(ms), Arc::new(SystemClock), Box::new(busy))
        });
        let idle_weak = idle.as_ref().map(Arc::downgrade);
        let signal = Arc::downgrade(&engines);
        // A provider connected or left: the idle stop and waiting sessions see it.
        let on_change: Arc<dyn Fn() + Send + Sync> = Arc::new(move || {
            if let Some(idle) = idle_weak.as_ref().and_then(std::sync::Weak::upgrade) {
                idle.changed();
            }
            if let Some(engines) = signal.upgrade() {
                engines.provider_changed();
            }
        });
        host.on_sessions_changed(on_change.clone());
        if let Some(secret) = secret {
            let provider_listener = match options.provider_listen_fd {
                Some(fd) => inherited_listener(fd, "--provider-listen-fd"),
                None => bind(
                    &cmux_browser_host::server::provider_socket_path(&options.socket),
                    owns_dir,
                )
                .map_err(|error| error.to_string()),
            };
            let started = provider_listener.and_then(|listener| {
                start_provider_listener(listener, secret, &engines, on_change)
            });
            if let Err(error) = started {
                eprintln!("cmux-browser-host: provider listener: {error}");
                return 1;
            }
        }
        if options.supervised {
            supervise_from_stdin();
        }
        if let Some(idle) = idle {
            let spawned =
                std::thread::Builder::new().name("supervisor-idle".into()).spawn(move || {
                    if idle.wait() {
                        // crash-allow: the idle stop; nothing to save (no session, no provider), and the daemon starts the host again on the next agent connect.
                        std::process::exit(0);
                    }
                });
            if spawned.is_err() {
                eprintln!("cmux-browser-host: cannot start the idle stop; running without it");
            }
        }
        match serve(listener, host) {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                1
            }
        }
    }

    /// `--supervised`: both sockets listen now, so the daemon may hand out
    /// the credentials; then a thread waits for the end of stdin (the
    /// daemon's end of the pipe closes when it stops or dies) and exits.
    fn supervise_from_stdin() {
        let mut stdout = std::io::stdout().lock();
        // A daemon that cannot read the ready line is gone: stop with it.
        if writeln!(stdout, "ready").and_then(|()| stdout.flush()).is_err() {
            // crash-allow: a supervised host whose daemon is gone stops; no state to save (sessions are in memory).
            std::process::exit(0);
        }
        drop(stdout);
        let spawned = std::thread::Builder::new().name("supervisor-stdin".into()).spawn(|| {
            let mut sink = [0_u8; 256];
            let mut stdin = std::io::stdin().lock();
            // Bytes from the daemon mean nothing; only the end does.
            while matches!(stdin.read(&mut sink), Ok(n) if n > 0) {}
            // crash-allow: the end of stdin means the daemon stopped or died; the host stops with it.
            std::process::exit(0);
        });
        if spawned.is_err() {
            eprintln!("cmux-browser-host: cannot watch stdin; stopping");
            // crash-allow: without the stdin watch a supervised host could outlive its daemon.
            std::process::exit(1);
        }
    }

    /// Connects, starting a host in the background when none answers,
    /// except on a socket a cmux daemon owns: there the daemon starts and
    /// supervises the host (with the app's provider secret), and a host
    /// started here would take its socket, so this waits for it instead.
    fn connect(options: &Options) -> Result<UnixStream, String> {
        if let Ok(stream) = UnixStream::connect(&options.socket) {
            return Ok(stream);
        }
        if daemon_owns(&options.socket) {
            return wait_for(&options.socket).map_err(|()| {
                format!(
                    "the cmux daemon's browser host does not answer on {}",
                    options.socket.display()
                )
            });
        }
        let exe = std::env::current_exe().map_err(|e| format!("cannot find myself: {e}"))?;
        std::process::Command::new(exe)
            .args(["serve", "--socket"])
            .arg(&options.socket)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            // Its own process group: Ctrl-C in the caller's terminal must
            // not stop a host that other sessions use.
            .process_group(0)
            .spawn()
            .map_err(|e| format!("cannot start the browser host: {e}"))?;
        wait_for(&options.socket)
            .map_err(|()| format!("the browser host did not start on {}", options.socket.display()))
    }

    /// The daemon's terminals name its host socket in `CMUX_BROWSER_HOST_SOCKET`
    /// next to `CMUX_TUI_SOCKET`.
    fn daemon_owns(socket: &std::path::Path) -> bool {
        let named = std::env::var_os("CMUX_BROWSER_HOST_SOCKET").filter(|p| !p.is_empty());
        let in_daemon = std::env::var_os("CMUX_TUI_SOCKET").is_some_and(|p| !p.is_empty());
        in_daemon && named.is_some_and(|named| std::path::Path::new(&named) == socket)
    }

    /// Connects within 10 seconds (a host that is starting).
    fn wait_for(socket: &std::path::Path) -> Result<UnixStream, ()> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(stream) = UnixStream::connect(socket) {
                return Ok(stream);
            }
            if Instant::now() >= deadline {
                return Err(());
            }
            // A bounded connect retry while the host starts, not a synchronization.
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn request(
        stream: &mut UnixStream,
        id: u64,
        method: &str,
        params: Value,
    ) -> Result<Value, Value> {
        let line = json!({"id": id, "method": method, "params": params, "origin": "cli"});
        writeln!(stream, "{line}")
            .map_err(|e| json!({"code": "closed", "message": e.to_string()}))?;
        let mut reader = BufReader::new(
            stream.try_clone().map_err(|e| json!({"code": "closed", "message": e.to_string()}))?,
        );
        let mut reply = String::new();
        reader
            .read_line(&mut reply)
            .map_err(|e| json!({"code": "closed", "message": e.to_string()}))?;
        let reply: Value = serde_json::from_str(&reply).map_err(
            |_| json!({"code": "closed", "message": "the browser host closed the connection"}),
        )?;
        match reply.get("error") {
            Some(error) if !error.is_null() => Err(error.clone()),
            _ => Ok(reply.get("result").cloned().unwrap_or(Value::Null)),
        }
    }

    fn simple(options: &Options, method: &str, params: Value) -> i32 {
        let mut stream = match connect(options) {
            Ok(stream) => stream,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                return 1;
            }
        };
        match request(&mut stream, 1, method, params) {
            Ok(result) => {
                println!("{}", serde_json::to_string_pretty(&result).unwrap_or_default());
                0
            }
            Err(error) => {
                eprintln!("{}", error["message"].as_str().unwrap_or("error"));
                1
            }
        }
    }

    /// A request whose answer is not printed (cleanup).
    fn simple_quiet(options: &Options, method: &str, params: Value) {
        if let Ok(mut stream) = connect(options) {
            let _ = request(&mut stream, 1, method, params);
        }
    }

    /// Without `--session` the call is a one-shot session, as `cmux browser
    /// repl --eval` is: its own name, closed after the call, so nothing
    /// (variables, tabs, ref numbers) carries over to the next call.
    fn eval_command(options: &Options, named: bool) -> i32 {
        let Some(code) = &options.code else {
            eprintln!("cmux-browser-host eval: pass code or - for stdin");
            return 2;
        };
        if !named {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let mut one_shot = options.clone();
            one_shot.session = format!("oneshot-{}-{nanos:x}", std::process::id());
            let code = eval_in(&one_shot, code);
            simple_quiet(&one_shot, "browser.repl.close", json!({"session": one_shot.session}));
            return code;
        }
        eval_in(options, code)
    }

    fn eval_in(options: &Options, code: &str) -> i32 {
        let mut stream = match connect(options) {
            Ok(stream) => stream,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                return 1;
            }
        };
        if let Err(error) = request(
            &mut stream,
            1,
            "browser.repl.open",
            json!({"session": options.session, "engine": options.engine, "cwd": caller_cwd()}),
        ) {
            eprintln!("{}", error["message"].as_str().unwrap_or("error"));
            return 1;
        }
        let mut params = json!({"session": options.session, "code": code});
        if let Some(max) = options.max_output {
            params["maxOutput"] = json!(max);
        }
        if let Some(ms) = options.timeout_ms {
            params["timeoutMs"] = json!(ms);
        }
        match request(&mut stream, 2, "browser.repl.eval", params) {
            Ok(result) => {
                print!("{}", result["output"].as_str().unwrap_or(""));
                match result["error"].as_str() {
                    Some(error) => {
                        eprintln!("{error}");
                        1
                    }
                    None => 0,
                }
            }
            Err(error) => {
                eprintln!("{}", error["message"].as_str().unwrap_or("error"));
                1
            }
        }
    }

    /// The caller's directory, the session's fs root when it is narrow enough.
    fn caller_cwd() -> String {
        std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_default()
    }
}
