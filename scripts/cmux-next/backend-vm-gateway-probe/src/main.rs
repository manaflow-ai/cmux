//! Explicitly opt-in measurement of a dedicated development backend across a VM pause.
//! No VM discovery, provisioning, deletion, backend selection or default changes.
use reqwest::{blocking::Client, redirect::Policy, Url};
use serde_json::{json, Value};
use std::{
    io::Read,
    thread,
    time::{Duration, Instant},
};

type Result<T> = std::result::Result<T, String>;
const USAGE: &str = "backend-vm-gateway-probe --experiment backend-vm-gateway --dedicated-vm ID --health-url https://HOST/api/health [--samples 1..50] [--pause-seconds 1..3600]\nRun only on an isolated development-backend VM with no other users. FREESTYLE_API_KEY is read from the environment. Without --experiment, no request is sent.";

#[derive(Debug)]
struct Config {
    vm: String,
    health: Url,
    samples: usize,
    pause: Duration,
}
impl Config {
    fn parse(args: &[String]) -> Result<Self> {
        if args.len() % 2 != 0 {
            return Err(USAGE.into());
        }
        let mut fields = std::collections::BTreeMap::new();
        for pair in args.chunks_exact(2) {
            if ![
                "--experiment",
                "--dedicated-vm",
                "--health-url",
                "--samples",
                "--pause-seconds",
            ]
            .contains(&pair[0].as_str())
                || fields.insert(pair[0].as_str(), pair[1].as_str()).is_some()
            {
                return Err(format!("Unknown or duplicate option. {USAGE}"));
            }
        }
        if fields.get("--experiment") != Some(&"backend-vm-gateway") {
            return Err(format!("Experiment is off. {USAGE}"));
        }
        let vm = fields.get("--dedicated-vm").ok_or(USAGE)?.to_string();
        if vm.is_empty()
            || vm.len() > 128
            || !vm
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(
                "Invalid dedicated VM id; pass the exact id of your isolated development backend."
                    .into(),
            );
        }
        let health = Url::parse(fields.get("--health-url").ok_or(USAGE)?)
            .map_err(|_| "Invalid health URL; use an HTTPS /api/health endpoint.")?;
        if health.scheme() != "https"
            || health.host_str().is_none()
            || !health.username().is_empty()
            || health.password().is_some()
            || health.query().is_some()
            || health.fragment().is_some()
            || health.path() != "/api/health"
        {
            return Err(
                "Health URL must be HTTPS /api/health without credentials, query or fragment."
                    .into(),
            );
        }
        let number = |name, default, max| -> Result<usize> {
            let n = fields
                .get(name)
                .copied()
                .unwrap_or(default)
                .parse::<usize>()
                .map_err(|_| format!("Invalid {name}. {USAGE}"))?;
            if n == 0 || n > max {
                Err(format!("Out of range {name}. {USAGE}"))
            } else {
                Ok(n)
            }
        };
        Ok(Self {
            vm,
            health,
            samples: number("--samples", "1", 50)?,
            pause: Duration::from_secs(number("--pause-seconds", "60", 3600)? as u64),
        })
    }
}

#[derive(Debug, Clone)]
struct Health {
    first_byte_ms: f64,
    complete_ms: f64,
}
trait Backend {
    fn state(&mut self, timeout: Duration) -> Result<String>;
    fn pause(&mut self) -> Result<()>;
    fn start(&mut self) -> Result<()>;
    fn health(&mut self) -> Result<Health>;
    fn hold(&mut self, duration: Duration) {
        thread::sleep(duration);
    }
}
struct HttpBackend {
    client: Client,
    provider: Url,
    vm: String,
    health: Url,
    key: String,
}
impl HttpBackend {
    fn new(config: &Config, key: String) -> Result<Self> {
        Ok(Self {
            client: Client::builder()
                .redirect(Policy::none())
                .timeout(Duration::from_secs(15))
                .build()
                .map_err(|_| "Could not initialize HTTPS; check the runner's TLS configuration.")?,
            provider: Url::parse("https://api.freestyle.sh/").expect("constant URL"),
            vm: config.vm.clone(),
            health: config.health.clone(),
            key,
        })
    }
    fn request(&self, method: reqwest::Method, suffix: &str, timeout: Duration) -> Result<Value> {
        let url = self
            .provider
            .join(&format!("v5/vms/{}{suffix}", self.vm))
            .map_err(|_| "Invalid provider route.")?;
        let mut response = self
            .client
            .request(method, url)
            .bearer_auth(&self.key)
            .timeout(timeout)
            .send()
            .map_err(|_| {
                "Provider request failed or timed out; inspect the dedicated VM before retrying."
            })?;
        if !response.status().is_success() {
            return Err(format!(
                "Provider returned HTTP {}; inspect the dedicated VM before retrying.",
                response.status().as_u16()
            ));
        }
        if suffix != "" {
            return Ok(Value::Null);
        }
        let mut body = Vec::new();
        response
            .by_ref()
            .take(65537)
            .read_to_end(&mut body)
            .map_err(|_| "Could not read provider state; inspect the dedicated VM.")?;
        if body.len() > 65536 {
            return Err("Provider state exceeded 64 KiB; inspect the response contract.".into());
        }
        serde_json::from_slice(&body)
            .map_err(|_| "Provider state was not JSON; inspect the response contract.".into())
    }
}
impl Backend for HttpBackend {
    fn state(&mut self, timeout: Duration) -> Result<String> {
        self.request(reqwest::Method::GET, "", timeout)?["state"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| "Provider omitted VM state; inspect the dedicated VM.".into())
    }
    fn pause(&mut self) -> Result<()> {
        self.request(reqwest::Method::POST, "/pause", Duration::from_secs(15))
            .map(|_| ())
    }
    fn start(&mut self) -> Result<()> {
        self.request(reqwest::Method::POST, "/start", Duration::from_secs(15))
            .map(|_| ())
    }
    fn health(&mut self) -> Result<Health> {
        let began = Instant::now();
        // A separate request: never send the provider credential to the backend, never follow a redirect.
        let mut response = self.client.get(self.health.clone()).timeout(Duration::from_secs(5)).send()
            .map_err(|_| "Backend health request failed within its 5 s deadline; inspect /api/health and the backend services.")?;
        if !response.status().is_success() {
            return Err(format!(
                "Backend health returned HTTP {}; inspect the backend services.",
                response.status().as_u16()
            ));
        }
        let mut first = [0u8; 1];
        response
            .read_exact(&mut first)
            .map_err(|_| "Backend health was empty or timed out; inspect /api/health.")?;
        let first_byte_ms = began.elapsed().as_secs_f64() * 1000.0;
        let mut body = vec![first[0]];
        response
            .take(65536)
            .read_to_end(&mut body)
            .map_err(|_| "Backend health body failed; inspect /api/health.")?;
        if body.len() > 65536 {
            return Err("Backend health exceeded 64 KiB; inspect /api/health.".into());
        }
        let value: Value = serde_json::from_slice(&body).map_err(|_| {
            "Backend health must be JSON, not a login/error page; inspect /api/health."
        })?;
        if value["status"] != "ok" && value["status"] != "healthy" {
            return Err("Backend health must report status ok or healthy; provide an aggregate /api/health for the development stack.".into());
        }
        Ok(Health {
            first_byte_ms,
            complete_ms: began.elapsed().as_secs_f64() * 1000.0,
        })
    }
}

fn wait_paused(backend: &mut impl Backend) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("Pause did not reach paused within 30 s; inspect the dedicated VM.".into());
        }
        if backend.state(remaining.min(Duration::from_secs(5)))? == "paused" {
            return Ok(());
        }
        backend.hold(remaining.min(Duration::from_millis(250)));
    }
}

fn sample(backend: &mut impl Backend, hold: Duration) -> Result<Value> {
    // Preserve existing machines: only a healthy, running, operator-selected test VM may be paused.
    if backend.state(Duration::from_secs(5))? != "running" {
        return Err("Dedicated VM is not running; start and inspect it before retrying.".into());
    }
    let before = backend.health()?;
    let pause_began = Instant::now();
    // Any failure after an attempted pause gets one bounded start attempt, even a lost pause response.
    let result: Result<Value> = (|| {
        backend.pause()?;
        let pause_ack_ms = pause_began.elapsed().as_secs_f64() * 1000.0;
        wait_paused(backend)?;
        backend.hold(hold); // No health or exec traffic while it should be paused.
        if backend.state(Duration::from_secs(5))? != "paused" {
            return Err("VM woke during the hold; discard this sample and remove background traffic before retrying.".into());
        }
        let resume_began = Instant::now();
        backend.start()?;
        let resume_ack_ms = resume_began.elapsed().as_secs_f64() * 1000.0;
        let health_began_ms = resume_began.elapsed().as_secs_f64() * 1000.0;
        let after = backend.health()?; // Exactly one health read after explicit start, with a 5 s deadline.
        Ok(
            json!({"kind":"sample", "pause_seconds":hold.as_secs(), "pause_ack_ms":pause_ack_ms,
            "running_health_first_byte_ms":before.first_byte_ms, "resume_ack_ms":resume_ack_ms,
            "resume_to_health_first_byte_ms":health_began_ms + after.first_byte_ms,
            "resume_to_healthy_ms":health_began_ms + after.complete_ms}),
        )
    })();
    match result {
        Ok(row) => Ok(row),
        Err(error) => match backend.start() {
            Ok(()) => Err(format!("{error} Recovery start acknowledged; verify the backend is healthy before retrying.")),
            Err(_) => Err(format!("{error} Recovery start failed; start the dedicated VM through the provider console now.")),
        }
    }
}
fn percentile(values: &mut [f64], percentile: f64) -> f64 {
    values.sort_by(f64::total_cmp);
    values[((values.len() as f64 * percentile).ceil() as usize).saturating_sub(1)]
}
fn run(config: &Config, backend: &mut impl Backend, mut emit: impl FnMut(Value)) -> Result<()> {
    let mut baseline = Vec::new();
    let mut resumed = Vec::new();
    for index in 0..config.samples {
        let mut row = sample(backend, config.pause)?;
        row["sample"] = json!(index + 1);
        row["experiment"] = json!("backend-vm-gateway");
        row["vm_id"] = json!(config.vm);
        row["health_url"] = json!(config.health.as_str());
        row["requested_samples"] = json!(config.samples);
        baseline.push(
            row["running_health_first_byte_ms"]
                .as_f64()
                .expect("numeric sample"),
        );
        resumed.push(
            row["resume_to_health_first_byte_ms"]
                .as_f64()
                .expect("numeric sample"),
        );
        emit(row);
    }
    let p95 = percentile(&mut resumed, 0.95);
    emit(
        json!({"kind":"summary", "experiment":"backend-vm-gateway", "vm_id":config.vm,
        "health_url":config.health.as_str(), "samples":config.samples, "pause_seconds":config.pause.as_secs(),
        "running_health_p50_ms":percentile(&mut baseline, 0.5), "running_health_p95_ms":percentile(&mut baseline, 0.95),
        "resume_to_health_p50_ms":percentile(&mut resumed, 0.5), "resume_to_health_p95_ms":p95,
        "wake_target_p95_ms":2000, "wake_target_met_in_this_run":config.samples == 50 && p95 < 2000.0,
        "cold_tag_target_ms":10000, "cold_tag_measured":false,
        "scope":"direct provider start to backend health; excludes gateway proxy hop and database correctness"}),
    );
    Ok(())
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--help"] {
        println!("{USAGE}");
        return;
    }
    let result = (|| {
        let config = Config::parse(&args)?;
        let key = std::env::var("FREESTYLE_API_KEY").ok().filter(|v| !v.trim().is_empty())
            .ok_or("Missing FREESTYLE_API_KEY; inject the scoped development provider credential through the approved secret store.")?;
        run(&config, &mut HttpBackend::new(&config, key)?, |row| {
            println!("{row}")
        })
    })();
    if let Err(error) = result {
        eprintln!("{}", json!({"kind":"failure", "error":error}));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    fn args() -> Vec<String> {
        [
            "--experiment",
            "backend-vm-gateway",
            "--dedicated-vm",
            "probe-1",
            "--health-url",
            "https://test.example/api/health",
        ]
        .map(str::to_owned)
        .to_vec()
    }
    #[test]
    fn disabled_and_invalid_inputs_never_reach_transport() {
        assert!(Config::parse(&[]).is_err());
        for bad in [
            "http://test.example/api/health",
            "https://key@test.example/api/health",
            "https://test.example/login",
            "https://test.example/api/health?key=secret",
        ] {
            let mut input = args();
            input[5] = bad.into();
            assert!(Config::parse(&input).is_err());
        }
        for pair in [
            ["--samples", "0"],
            ["--samples", "51"],
            ["--pause-seconds", "3601"],
            ["--experiment", "backend-vm-gateway"],
        ] {
            let mut input = args();
            input.extend(pair.map(str::to_owned));
            assert!(Config::parse(&input).is_err());
        }
    }
    struct Fake {
        calls: Vec<&'static str>,
        states: VecDeque<&'static str>,
        health_reads: usize,
        fail_health: bool,
        fail_pause: bool,
        fail_start: bool,
    }
    impl Fake {
        fn new() -> Self {
            Self {
                calls: vec![],
                states: ["running", "paused", "paused"].into(),
                health_reads: 0,
                fail_health: false,
                fail_pause: false,
                fail_start: false,
            }
        }
    }
    impl Backend for Fake {
        fn state(&mut self, _: Duration) -> Result<String> {
            self.calls.push("state");
            Ok(self
                .states
                .pop_front()
                .expect("unexpected state request")
                .into())
        }
        fn pause(&mut self) -> Result<()> {
            self.calls.push("pause");
            if self.fail_pause {
                Err("lost pause response".into())
            } else {
                Ok(())
            }
        }
        fn start(&mut self) -> Result<()> {
            self.calls.push("start");
            if self.fail_start {
                Err("start failed".into())
            } else {
                Ok(())
            }
        }
        fn health(&mut self) -> Result<Health> {
            self.calls.push("health");
            self.health_reads += 1;
            if self.fail_health && self.health_reads > 1 {
                Err("unhealthy after resume".into())
            } else {
                Ok(Health {
                    first_byte_ms: 3.0,
                    complete_ms: 4.0,
                })
            }
        }
        fn hold(&mut self, _: Duration) {
            self.calls.push("hold");
        }
    }
    #[test]
    fn backend_flow_has_one_post_resume_health_read_and_bound_summary() {
        let config = Config::parse(&args()).unwrap();
        let mut fake = Fake::new();
        let mut rows = vec![];
        run(&config, &mut fake, |v| rows.push(v)).unwrap();
        assert_eq!(
            fake.calls,
            ["state", "health", "pause", "state", "hold", "state", "start", "health"]
        );
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["vm_id"], "probe-1");
        assert_eq!(rows[0]["health_url"], "https://test.example/api/health");
        assert_eq!(rows[0]["requested_samples"], 1);
        assert_eq!(rows[1]["samples"], 1);
        assert_eq!(rows[1]["vm_id"], "probe-1");
        assert_eq!(rows[1]["wake_target_met_in_this_run"], false);
        assert_eq!(rows[1]["cold_tag_measured"], false);
    }
    #[test]
    fn unhealthy_resume_recovers_and_never_emits_a_success() {
        let mut fake = Fake::new();
        fake.fail_health = true;
        let mut rows = vec![];
        let error = run(&Config::parse(&args()).unwrap(), &mut fake, |v| {
            rows.push(v)
        })
        .unwrap_err();
        assert!(rows.is_empty());
        assert!(error.contains("Recovery start acknowledged"));
        assert_eq!(fake.calls.iter().filter(|c| **c == "start").count(), 2);
    }
    #[test]
    fn lost_pause_answer_attempts_recovery_and_failed_recovery_names_action() {
        let mut fake = Fake::new();
        fake.fail_pause = true;
        fake.fail_start = true;
        let error = sample(&mut fake, Duration::ZERO).unwrap_err();
        assert!(error.contains("provider console now"));
        assert_eq!(fake.calls, ["state", "health", "pause", "start"]);
    }
    #[test]
    fn early_wake_is_not_a_resume_sample() {
        let mut fake = Fake::new();
        fake.states[2] = "running";
        assert!(sample(&mut fake, Duration::ZERO)
            .unwrap_err()
            .contains("woke during the hold"));
        assert_eq!(fake.health_reads, 1);
    }
    #[test]
    fn preflight_does_not_mutate_a_paused_vm() {
        let mut fake = Fake::new();
        fake.states[0] = "paused";
        assert!(sample(&mut fake, Duration::ZERO).is_err());
        assert_eq!(fake.calls, ["state"]);
    }
    #[test]
    fn nearest_rank_percentiles() {
        assert_eq!(
            percentile(&mut (1..=50).map(f64::from).collect::<Vec<_>>(), 0.95),
            48.0
        );
    }
    #[test]
    fn http_round_trip_keeps_provider_key_off_health() {
        use std::{io::Write, net::TcpListener};
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}/", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            for (method, path, body, credential) in [
                ("GET", "/v5/vms/probe-1", r#"{"state":"running"}"#, true),
                ("GET", "/api/health", r#"{"status":"ok"}"#, false),
                ("POST", "/v5/vms/probe-1/pause", "{}", true),
                ("GET", "/v5/vms/probe-1", r#"{"state":"paused"}"#, true),
                ("GET", "/v5/vms/probe-1", r#"{"state":"paused"}"#, true),
                ("POST", "/v5/vms/probe-1/start", "{}", true),
                ("GET", "/api/health", r#"{"status":"healthy"}"#, false),
            ] {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = vec![];
                while !request.ends_with(b"\r\n\r\n") {
                    let mut byte = [0];
                    socket.read_exact(&mut byte).unwrap();
                    request.push(byte[0]);
                    assert!(request.len() < 8192);
                }
                let text = String::from_utf8(request).unwrap().to_lowercase();
                assert!(text.starts_with(&format!("{} {} http/1.1", method.to_lowercase(), path)));
                assert_eq!(
                    text.contains("authorization: bearer test-secret"),
                    credential
                );
                write!(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
            }
        });
        let config = Config::parse(&args()).unwrap();
        let mut backend = HttpBackend::new(&config, "test-secret".into()).unwrap();
        backend.provider = Url::parse(&origin).unwrap();
        backend.health = backend.provider.join("api/health").unwrap();
        let sample = sample(&mut backend, Duration::ZERO).unwrap();
        assert_eq!(sample["kind"], "sample");
        server.join().unwrap();
    }
    #[test]
    fn health_does_not_follow_redirects_or_accept_html() {
        use std::{io::Write, net::TcpListener};
        for (status, body) in [
            ("302 Found", ""),
            ("200 OK", "<html>login</html>"),
            ("200 OK", r#"{"status":"unhealthy"}"#),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let health = Url::parse(&format!(
                "http://{}/api/health",
                listener.local_addr().unwrap()
            ))
            .unwrap();
            let server = thread::spawn(move || {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = vec![];
                while !request.ends_with(b"\r\n\r\n") {
                    let mut byte = [0];
                    socket.read_exact(&mut byte).unwrap();
                    request.push(byte[0]);
                }
                write!(socket, "HTTP/1.1 {status}\r\nLocation: https://must-not-follow.invalid/\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            });
            let mut backend =
                HttpBackend::new(&Config::parse(&args()).unwrap(), "test-secret".into()).unwrap();
            backend.health = health;
            assert!(backend.health().is_err());
            server.join().unwrap();
        }
    }
}
