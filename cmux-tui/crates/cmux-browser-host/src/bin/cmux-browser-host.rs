//! `cmux-browser-host`: the browser host until `cmux browser host` exists in
//! the Rust cmux binary (#16174).
//!
//!   cmux-browser-host serve [--socket PATH]
//!   cmux-browser-host eval [--session NAME] [--engine E] [--max-output N] [--timeout-ms N] (-|CODE)
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
}
