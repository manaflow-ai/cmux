//! `cmux-browser-host`: the browser host until `cmux browser host` exists in
//! the Rust cmux binary (#16174).
//!
//!   cmux-browser-host serve [--socket PATH]
//!   cmux-browser-host eval [--session NAME] [--engine E] [--max-output N] [--timeout-ms N] (-|CODE)
//!   cmux-browser-host mcp [--session NAME] [--engine E] [--timeout-ms N]
//!   cmux-browser-host list | close --session NAME | guide
//!
//! `eval` starts the host on demand when no host answers on the socket.

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
    use cmux_browser_host::mcp::{
        McpServer, code_for_tool, result_of_eval, screenshot_code, screenshot_result,
    };
    use cmux_browser_host::server::{bind, default_socket_path, serve};
    use serde_json::{Value, json};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::os::unix::net::UnixStream;
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
    }

    fn parse(args: &[String]) -> Result<Options, String> {
        let mut options = Options {
            socket: default_socket_path(),
            session: "default".into(),
            engine: std::env::var("CMUX_BROWSER_HOST_ENGINE").unwrap_or_else(|_| "auto".into()),
            max_output: None,
            timeout_ms: None,
            code: None,
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
            "serve" => serve_command(&options),
            "guide" => {
                print!("{}", bundle::GUIDE);
                0
            }
            "eval" => eval_command(&options),
            "mcp" => mcp_command(&options, rest.iter().any(|a| a == "--session")),
            "list" => simple(&options, "browser.repl.list", json!({})),
            "close" => simple(&options, "browser.repl.close", json!({"session": options.session})),
            other => {
                eprintln!("cmux-browser-host: unknown command {other}");
                2
            }
        }
    }

    fn serve_command(options: &Options) -> i32 {
        let listener = match bind(&options.socket) {
            Ok(listener) => listener,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                return 1;
            }
        };
        let cwd =
            std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_else(|_| "/".into());
        let host = Arc::new(Host::new(Arc::new(HostEngines::new(agent_bundle())), cwd));
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
            json!({"session": options.session, "engine": options.engine}),
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

    /// MCP server on stdio. Without `--session` each server gets its own
    /// session, closed when stdin ends, so two clients never share state by
    /// accident; a named session is how clients share one on purpose.
    fn mcp_command(options: &Options, named: bool) -> i32 {
        let mut stream = match connect(options) {
            Ok(stream) => stream,
            Err(error) => {
                eprintln!("cmux-browser-host: {error}");
                return 1;
            }
        };
        let session = if named {
            options.session.clone()
        } else {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.subsec_nanos())
                .unwrap_or(0);
            format!("mcp-{}-{nanos:x}", std::process::id())
        };
        let open = json!({"session": session, "engine": options.engine});
        if let Err(error) = request(&mut stream, 1, "browser.repl.open", open.clone()) {
            eprintln!("{}", error["message"].as_str().unwrap_or("error"));
            return 1;
        }
        let mut next_id = 2u64;
        let timeout = options.timeout_ms;
        let mut server = McpServer {
            version: env!("CARGO_PKG_VERSION").to_owned(),
            call_tool: |name: &str, arguments: &Value| -> Result<_, String> {
                next_id += 1;
                let mut eval = |code: String| -> Result<Value, String> {
                    let mut params = json!({"session": session, "code": code});
                    if let Some(ms) = timeout {
                        params["timeoutMs"] = json!(ms);
                    }
                    request(&mut stream, next_id, "browser.repl.eval", params)
                        .map_err(|e| e["message"].as_str().unwrap_or("error").to_owned())
                };
                match name {
                    "reset" => {
                        let closed = request(
                            &mut stream,
                            next_id,
                            "browser.repl.close",
                            json!({"session": session}),
                        )
                        .map_err(|e| e["message"].as_str().unwrap_or("error").to_owned())?;
                        request(&mut stream, next_id + 1, "browser.repl.open", open.clone())
                            .map_err(|e| e["message"].as_str().unwrap_or("error").to_owned())?;
                        next_id += 1;
                        let text = if closed["closed"].as_bool() == Some(true) {
                            format!("Session {session} reset")
                        } else {
                            format!("Session {session} had no state")
                        };
                        Ok(cmux_browser_host::mcp::ToolResult::text(text, false))
                    }
                    "screenshot" => {
                        let marker = "cmux-mcp-image:";
                        Ok(screenshot_result(&eval(screenshot_code(arguments, marker))?, marker))
                    }
                    other => {
                        let code = code_for_tool(other, arguments)
                            .ok_or_else(|| format!("Unknown tool: {other}"))?;
                        Ok(result_of_eval(&eval(code)?))
                    }
                }
            },
        };
        let stdin = std::io::stdin();
        let mut stdout = std::io::stdout();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            if let Some(reply) = server.handle_line(&line) {
                let _ = writeln!(stdout, "{reply}");
                let _ = stdout.flush();
            }
        }
        drop(server);
        if !named && let Ok(mut stream) = connect(options) {
            let _ = request(&mut stream, 1, "browser.repl.close", json!({"session": session}));
        }
        0
    }
}
