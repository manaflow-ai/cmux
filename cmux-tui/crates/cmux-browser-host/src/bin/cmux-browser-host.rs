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
    use cmux_browser_host::server::{bind, default_socket_path, serve};
    use serde_json::{Value, json};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::os::unix::net::UnixStream;
    use std::os::unix::process::CommandExt;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

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
            "eval" => eval_command(&options),
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
        socket: &std::path::Path,
        owns_dir: bool,
        secret: String,
        engines: &HostEngines,
    ) -> Result<(), String> {
        let path = cmux_browser_host::server::provider_socket_path(socket);
        let listener = bind(&path, owns_dir).map_err(|e| e.to_string())?;
        let slot = engines.provider_slot();
        let bundle: Arc<str> = agent_bundle().into();
        std::thread::Builder::new()
            .name("cmux-browser-host-providers".into())
            .spawn(move || {
                let secret = cmux_browser_host::provider::ProviderSecret::new(secret);
                let _ = cmux_browser_host::server::serve_providers(listener, secret, slot, bundle);
            })
            .map_err(|e| e.to_string())?;
        Ok(())
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
        let listener = match bind(&options.socket, owns_dir) {
            Ok(listener) => listener,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                return 1;
            }
        };
        let cwd =
            std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_else(|_| "/".into());
        let engines = Arc::new(HostEngines::new(agent_bundle()));
        if let Some(secret) = secret
            && let Err(error) = start_provider_listener(&options.socket, owns_dir, secret, &engines)
        {
            eprintln!("cmux-browser-host: provider listener: {error}");
            return 1;
        }
        let host = Arc::new(Host::new(engines, cwd));
        match serve(listener, host) {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                1
            }
        }
    }

    /// Connects, starting a host in the background when none answers.
    fn connect(options: &Options) -> Result<UnixStream, String> {
        if let Ok(stream) = UnixStream::connect(&options.socket) {
            return Ok(stream);
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
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(stream) = UnixStream::connect(&options.socket) {
                return Ok(stream);
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "the browser host did not start on {}",
                    options.socket.display()
                ));
            }
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

    fn eval_command(options: &Options) -> i32 {
        let Some(code) = &options.code else {
            eprintln!("cmux-browser-host eval: pass code or - for stdin");
            return 2;
        };
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
