//! Opt-in transport experiment; never started by the app or its production daemon.
//! Run with `--experiment` to compare the catalog's FFI and child-daemon paths.

#[cfg(unix)]
mod experiment {
    use std::collections::HashMap;
    use std::hint::black_box;
    use std::io::{self, Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::Path;
    use std::process::{Child, Command};
    use std::time::{Duration, Instant};

    use cmux_action_catalog::{ffi, json, strings};
    use serde_json::{Value, json};
    use wait_timeout::ChildExt;

    const DEADLINE: Duration = Duration::from_secs(5);
    const MAX_REQUEST: usize = 4096;
    const MAX_RESPONSE: usize = 8 * 1024 * 1024;

    fn invalid(message: &str) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidData, message)
    }

    fn configure(stream: &UnixStream) -> io::Result<()> {
        stream.set_read_timeout(Some(DEADLINE))?;
        stream.set_write_timeout(Some(DEADLINE))
    }

    fn read_frame(stream: &mut UnixStream, limit: usize) -> io::Result<Vec<u8>> {
        let mut header = [0; 4];
        stream.read_exact(&mut header)?;
        let len = u32::from_be_bytes(header) as usize;
        if len > limit {
            return Err(invalid("catalog RPC frame exceeds limit"));
        }
        let mut bytes = vec![0; len];
        stream.read_exact(&mut bytes)?;
        Ok(bytes)
    }

    fn write_frame(stream: &mut UnixStream, bytes: &[u8]) -> io::Result<()> {
        let len = u32::try_from(bytes.len()).map_err(|_| invalid("frame too large"))?;
        stream.write_all(&len.to_be_bytes())?;
        stream.write_all(bytes)
    }

    fn serve(path: &Path) -> io::Result<()> {
        let mut stream = UnixStream::connect(path)?;
        configure(&stream)?;
        // Index, not the caller's arbitrary locale string: bounded by LOCALES.len().
        let mut catalogs = HashMap::new();
        loop {
            let request: Value = serde_json::from_slice(&read_frame(&mut stream, MAX_REQUEST)?)?;
            match request.get("method").and_then(Value::as_str) {
                Some("shutdown") => return Ok(()),
                Some("catalog.get") => {
                    let Some(locale) = request.get("locale").and_then(Value::as_str) else {
                        write_frame(&mut stream, br#"{"error":"locale must be a string"}"#)?;
                        continue;
                    };
                    let index = strings::locale_index(locale);
                    let text = catalogs.entry(index).or_insert_with(|| json::catalog(index));
                    write_frame(&mut stream, text.as_bytes())?;
                }
                _ => write_frame(&mut stream, br#"{"error":"unknown method"}"#)?,
            }
        }
    }

    struct Daemon {
        child: Child,
        stream: UnixStream,
        directory: tempfile::TempDir,
    }

    impl Daemon {
        fn start() -> io::Result<Self> {
            // tempfile creates an exclusive mode-0700 directory: no shared socket name.
            let directory = tempfile::Builder::new().prefix("catalog-rpc-").tempdir()?;
            let path = directory.path().join("rpc.sock");
            let listener = UnixListener::bind(&path)?;
            let mut child =
                Command::new(std::env::current_exe()?).arg("--serve").arg(&path).spawn()?;
            let (sender, receiver) = std::sync::mpsc::sync_channel(1);
            let accept = std::thread::spawn(move || {
                let _ = sender.send(listener.accept().map(|(stream, _)| stream));
            });
            let connected = receiver.recv_timeout(DEADLINE);
            if connected.is_err() {
                let _ = child.kill();
                let _ = child.wait();
                // Wake our accept thread before removing its exclusively owned directory.
                let _ = UnixStream::connect(&path);
            }
            let _ = accept.join();
            let stream = match connected {
                Ok(Ok(stream)) => stream,
                result => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(invalid(&format!("catalog daemon failed to connect: {result:?}")));
                }
            };
            let daemon = Self { child, stream, directory };
            configure(&daemon.stream)?;
            Ok(daemon)
        }

        fn request(&mut self, request: &Value) -> io::Result<Value> {
            write_frame(&mut self.stream, &serde_json::to_vec(request)?)?;
            Ok(serde_json::from_slice(&read_frame(&mut self.stream, MAX_RESPONSE)?)?)
        }

        fn stop(mut self) -> io::Result<()> {
            write_frame(&mut self.stream, br#"{"method":"shutdown"}"#)?;
            match self.child.wait_timeout(DEADLINE)? {
                Some(status) if status.success() => Ok(()),
                status => Err(invalid(&format!("catalog daemon did not shut down: {status:?}"))),
            }
        }
    }

    impl Drop for Daemon {
        fn drop(&mut self) {
            // Also covers parse errors, timeouts and failed assertions: only our own child.
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    fn ffi_catalog(locale: &str) -> io::Result<Value> {
        let mut ptr = std::ptr::null();
        let mut len = 0;
        // SAFETY: locale is a live slice and both output pointers are writable locals.
        let status = unsafe {
            ffi::cmux_action_catalog_json(locale.as_ptr(), locale.len(), &mut ptr, &mut len)
        };
        if status != ffi::OK {
            return Err(invalid("catalog FFI failed"));
        }
        // SAFETY: on OK the FFI owns these bytes for the lifetime of this process.
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        Ok(serde_json::from_slice(bytes)?)
    }

    fn percentile(samples: &mut [u128], percent: usize) -> u128 {
        samples.sort_unstable();
        samples[(samples.len() * percent).div_ceil(100).saturating_sub(1)]
    }

    fn measure(mut action: impl FnMut() -> io::Result<Value>) -> io::Result<u128> {
        let start = Instant::now();
        drop(black_box(action()?));
        Ok(start.elapsed().as_nanos())
    }

    fn benchmark(samples: usize) -> io::Result<()> {
        let mut daemon = Daemon::start()?;
        let socket = daemon.directory.path().join("rpc.sock");
        let child_pid = daemon.child.id();
        let mut rows = Vec::new();
        for locale in ["en-US", "ja-JP", "pt_BR", "unknown-locale"] {
            let request = json!({"method": "catalog.get", "locale": locale});
            let expected = ffi_catalog(locale)?;
            let actual = daemon.request(&request)?;
            if actual != expected {
                return Err(invalid("RPC catalog differs from the app FFI catalog"));
            }
            let mut direct = Vec::with_capacity(samples);
            let mut rpc = Vec::with_capacity(samples);
            for iteration in 0..samples + 20 {
                // Alternate order to avoid consistently favoring the warmer path.
                let (a, b) = if iteration % 2 == 0 {
                    (measure(|| ffi_catalog(locale))?, measure(|| daemon.request(&request))?)
                } else {
                    let b = measure(|| daemon.request(&request))?;
                    (measure(|| ffi_catalog(locale))?, b)
                };
                if iteration >= 20 {
                    direct.push(a);
                    rpc.push(b);
                }
            }
            let direct_p99 = percentile(&mut direct, 99);
            let rpc_p99 = percentile(&mut rpc, 99);
            let ratio = rpc_p99 as f64 / direct_p99 as f64;
            rows.push(json!({
                "locale": locale, "parity": true, "samples": samples,
                "ffi_p50_ns": percentile(&mut direct, 50), "ffi_p99_ns": direct_p99,
                "rpc_p50_ns": percentile(&mut rpc, 50), "rpc_p99_ns": rpc_p99,
                "p99_ratio": ratio, "within_design_bar": ratio <= 1.2,
            }));
        }
        if daemon.request(&json!({"method": "no-such-method"}))?["error"] != "unknown method"
            || daemon.request(&json!({"method": "catalog.get", "locale": 4}))?["error"]
                != "locale must be a string"
        {
            return Err(invalid("invalid requests were not refused"));
        }
        daemon.stop()?;
        if socket.exists() {
            return Err(invalid("socket was not cleaned up"));
        }
        // Exercise the error cleanup path too: an oversized frame ends only this child.
        let mut broken = Daemon::start()?;
        let broken_socket = broken.directory.path().join("rpc.sock");
        broken.stream.write_all(&((MAX_REQUEST + 1) as u32).to_be_bytes())?;
        let refused = broken.child.wait_timeout(DEADLINE)?.is_some_and(|s| !s.success());
        drop(broken);
        if !refused || broken_socket.exists() {
            return Err(invalid("oversized request refusal/cleanup failed"));
        }
        // A peer that sends a header but never finishes the body cannot hold the daemon.
        let mut stalled = Daemon::start()?;
        let stalled_socket = stalled.directory.path().join("rpc.sock");
        stalled.stream.write_all(&10_u32.to_be_bytes())?;
        let timed_out = stalled
            .child
            .wait_timeout(DEADLINE + Duration::from_secs(1))?
            .is_some_and(|status| !status.success());
        drop(stalled);
        if !timed_out || stalled_socket.exists() {
            return Err(invalid("incomplete request timeout/cleanup failed"));
        }
        println!(
            "{}",
            json!({
                "experiment": "action-catalog-child-daemon", "production_caller_migrated": false,
                "child_pid": child_pid, "child_exited": true, "socket_removed": true,
                "invalid_requests_refused": true, "oversized_request_refused": true,
                "incomplete_request_timed_out": true,
                "measurement": "warm catalog retrieval and JSON decode/drop; not palette latency",
                "rows": rows,
            })
        );
        Ok(())
    }

    pub fn run() -> io::Result<()> {
        let args: Vec<_> = std::env::args().skip(1).collect();
        if args.first().map(String::as_str) == Some("--serve") && args.len() == 2 {
            return serve(Path::new(&args[1]));
        }
        if args.first().map(String::as_str) != Some("--experiment") || args.len() > 2 {
            return Err(invalid("opt in with --experiment [samples: 100..10000]"));
        }
        let samples = args
            .get(1)
            .map_or(Ok(500), |s| s.parse::<usize>())
            .map_err(|_| invalid("samples must be an integer"))?;
        if !(100..=10_000).contains(&samples) {
            return Err(invalid("samples must be 100..10000"));
        }
        benchmark(samples)
    }
}

fn main() -> std::io::Result<()> {
    #[cfg(unix)]
    return experiment::run();
    #[cfg(not(unix))]
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "requires a Unix socket"))
}
