//! Bounded I/O adapters. Clone work goes only through git-seed-v1; no git
//! clone process, credentials or second seed implementation lives here.
use super::{Backend, Catalog, Failure, Repo, add, list, store};
use crate::Mux;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const AGENT_SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
const IO_TIMEOUT: Duration = Duration::from_secs(20);
const CLONE_TIMEOUT: Duration = Duration::from_secs(9 * 60);
const MAX_REPLY: u64 = 4 * 1024 * 1024;
static ADDS: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();

fn transport_error() -> Failure {
    Failure::new("seed.clone_failed", "Reconnect to the Cloud machine, then retry Add repository.")
}
fn socket_request(path: &Path, request: &Value) -> Result<Value, Failure> {
    let mut socket = UnixStream::connect(path).map_err(|_| transport_error())?;
    socket.set_read_timeout(Some(IO_TIMEOUT)).map_err(|_| transport_error())?;
    socket.set_write_timeout(Some(IO_TIMEOUT)).map_err(|_| transport_error())?;
    writeln!(socket, "{request}").map_err(|_| transport_error())?;
    let mut line = String::new();
    BufReader::new(socket).take(MAX_REPLY).read_line(&mut line).map_err(|_| transport_error())?;
    if !line.ends_with('\n') {
        return Err(transport_error());
    }
    serde_json::from_str(&line).map_err(|_| transport_error())
}
struct Runtime<'a> {
    mux: &'a Mux,
    home: PathBuf,
    seed_socket: PathBuf,
    agent_socket: PathBuf,
}
impl<'a> Runtime<'a> {
    fn new(mux: &'a Mux, home: PathBuf) -> Self {
        Self {
            mux,
            home,
            seed_socket: mux
                .bound_socket_path
                .get()
                .cloned()
                .unwrap_or_else(|| crate::server::default_socket_path(&mux.session)),
            agent_socket: PathBuf::from(AGENT_SOCKET),
        }
    }

    fn seed(&self, cmd: &str, fields: Value, repo: &str) -> Result<Value, Failure> {
        let mut request = fields;
        request.set("id", json!("cloud-repo"));
        request.set("cmd", json!(cmd));
        let answer = socket_request(&self.seed_socket, &request)?;
        if answer.get("ok").and_then(Value::as_bool) == Some(false) {
            let mut error = answer.clone();
            for key in ["install_url", "org"] {
                if let Some(value) =
                    answer.get("error_details").and_then(|details| details.get(key))
                {
                    error.set(key, value.clone());
                }
            }
            return Err(self.seed_failure(&error, repo)?);
        }
        Ok(answer.get("data").cloned().unwrap_or(answer))
    }

    fn seed_failure(&self, value: &Value, repo: &str) -> Result<Failure, Failure> {
        let mut failure = super::engine::seed_failure(value);
        // Read the raw seed code: the engine may reject its unsafe/missing
        // URL, but the connector and the Mac can still supply a trusted one.
        let code = value
            .get("error_code")
            .and_then(Value::as_str)
            .or_else(|| value.get("code").and_then(Value::as_str));
        if matches!(code, Some("seed.needs_github" | "repo.needs_github")) {
            // A linked installation can still exclude this organization or
            // repo. Its recovery is access, not reconnecting the same account.
            let catalog = self.connector(Some(repo))?;
            if let Some(url) = catalog.install_url {
                failure = Failure::needs_github(&url);
            } else {
                let url = self.optional_install_url(value)?;
                failure = Failure::new(
                    "repo.no_access",
                    "Install GitHub access for this organization, or request access from its owner, then retry Add repository.",
                );
                if let Some((org, _)) = repo.split_once('/') {
                    failure.0.set("org", json!(org));
                }
                if let Some(url) = url {
                    failure.0.set("install_url", json!(url));
                }
            }
        } else if failure.0["code"] == "repo.no_access" {
            if let Some(url) = self.optional_install_url(value)? {
                failure.0.set("install_url", json!(url));
            }
        }
        Ok(failure)
    }

    fn wait_github(&self, timeout_ms: u64) -> Result<Value, Failure> {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms.min(60_000));
        loop {
            if self.connector(None)?.install_url.is_none() {
                return Ok(json!({"connected":true}));
            }
            if Instant::now() >= deadline {
                return Ok(json!({"connected":false}));
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    fn optional_install_url(&self, response: &Value) -> Result<Option<String>, Failure> {
        // The Mac obtained this link as the signed-in user; prefer it to
        // links carried by a connector or seed error. Both paths are checked.
        Ok(store::install_url(self.mux)?.or_else(|| {
            response
                .get("install_url")
                .and_then(Value::as_str)
                .filter(|url| super::engine::valid_install_url(url))
                .map(str::to_owned)
        }))
    }

    fn install_url(&self, response: &Value) -> Result<String, Failure> {
        self.optional_install_url(response)?.ok_or_else(super::engine::install_link_required)
    }
}
impl Backend for Runtime<'_> {
    fn sources(&self) -> Result<Vec<Repo>, Failure> {
        store::sources(self.mux)
    }
    fn connector(&self, query: Option<&str>) -> Result<Catalog, Failure> {
        let mut cursor: Option<String> = None;
        let mut seen = HashSet::new();
        let mut catalog = Catalog::default();
        let deadline = Instant::now() + Duration::from_secs(45);
        // A repeated cursor is an upstream error, never an infinite scan.
        for _ in 0..100 {
            if Instant::now() >= deadline {
                return Err(Failure::new(
                    "seed.clone_failed",
                    "Repository discovery timed out. Narrow the repository search and retry.",
                ));
            }
            let mut ask = json!({});
            if let Some(q) = query {
                ask.set("query", json!(q));
            }
            if let Some(c) = &cursor {
                ask.set("cursor", json!(c));
            }
            let answer = socket_request(&self.agent_socket, &json!({"github_repos":ask}))?;
            if answer.get("ok").and_then(Value::as_bool) != Some(true) {
                let error = answer.get("error").unwrap_or(&Value::Null);
                let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
                if code == "repo.needs_github" {
                    // Missing installation is the same recoverable state
                    // whether the bridge returns connect or a typed error.
                    return Ok(Catalog {
                        repos: Vec::new(),
                        install_url: Some(self.install_url(error)?),
                    });
                }
                let mut failure = Failure::new(
                    if code == "repo.no_access" { code } else { "seed.clone_failed" },
                    if code == "repo.no_access" {
                        "Install GitHub access for the repository's organization, or request access from its owner."
                    } else {
                        "Retry repository discovery. If it still fails, reconnect GitHub from Add repository."
                    },
                );
                if code == "repo.no_access" {
                    if let Some(url) = self.optional_install_url(error)? {
                        failure.0.set("install_url", json!(url));
                    }
                }
                return Err(failure);
            }
            if let Some(connect) = answer.get("connect").filter(|v| v.is_object()) {
                catalog.install_url = Some(self.install_url(connect)?);
            }
            let rows = answer.get("repos").and_then(Value::as_array).ok_or_else(transport_error)?;
            for row in rows {
                let name = row
                    .get("fullName")
                    .and_then(Value::as_str)
                    .filter(|r| super::engine::valid_repo(r))
                    .ok_or_else(transport_error)?;
                catalog.repos.push(Repo {
                    full_name: name.into(),
                    private: row.get("private").and_then(Value::as_bool).unwrap_or(true),
                    source: "installation".into(),
                });
            }
            cursor = answer.get("next_cursor").and_then(Value::as_str).map(str::to_owned);
            match &cursor {
                None => return Ok(catalog),
                Some(c) if seen.insert(c.clone()) => {}
                _ => return Err(transport_error()),
            }
        }
        Err(Failure::new("seed.bad_request", "Narrow the repository search and retry."))
    }
    fn attached(&self, session: &str) -> Result<Vec<Value>, Failure> {
        store::attached(self.mux, session)
    }
    fn clone_repo(
        &self,
        session: &str,
        repo: &str,
        reference: Option<&str>,
    ) -> Result<Value, Failure> {
        let name = repo.rsplit('/').next().ok_or_else(transport_error)?;
        let folder = self.home.join("chats").join(session).join(name);
        let key = format!("{session}/{}", name.to_ascii_lowercase());
        let lock = {
            let mut locks =
                ADDS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
            locks.retain(|_, lock| Arc::strong_count(lock) > 1);
            locks.entry(key).or_default().clone()
        };
        let _guard = lock.try_lock().map_err(|_| {
            Failure::new(
                "seed.clone_failed",
                "This repository is already being added. Wait for it to finish, then retry.",
            )
        })?;
        // A second call may have resolved before the first one recorded its result.
        if let Some(existing) = self.attached(session)?.into_iter().find(|r| {
            r.get("repo").and_then(Value::as_str).is_some_and(|r| r.eq_ignore_ascii_case(repo))
        }) {
            return Ok(existing);
        }
        let existing = store::job(self.mux, session, name)?;
        let job = if let Some(existing) = existing {
            if existing.get("repo").and_then(Value::as_str) != Some(repo)
                || existing.get("ref").unwrap_or(&Value::Null) != &json!(reference)
            {
                return Err(Failure::new(
                    "seed.folder_not_empty",
                    "Choose a different chat for this repository or branch; another add already uses that folder.",
                ));
            }
            existing.get("job").and_then(Value::as_str).ok_or_else(transport_error)?.to_owned()
        } else {
            let mut params =
                json!({"folder":folder,"url":format!("https://github.com/{repo}.git"),"repo":repo});
            if let Some(reference) = reference {
                params.set("ref", json!(reference));
            }
            let started = self.seed("git.seed.start", params, repo)?;
            let job =
                started.get("job").and_then(Value::as_str).ok_or_else(transport_error)?.to_owned();
            store::set_job(
                self.mux,
                session,
                name,
                Some(&json!({"job":job,"repo":repo,"ref":reference,"state":"running"})),
            )?;
            job
        };
        let deadline = Instant::now() + CLONE_TIMEOUT;
        let mut last_progress: Option<Instant> = None;
        loop {
            let status = match self.seed("git.seed.status", json!({"job":job}), repo) {
                Ok(status) => status,
                Err(failure) => {
                    // An expired/unknown job needs a fresh start on retry;
                    // transport failures retain it to avoid a duplicate clone.
                    // git-seed-v1 answers seed.unknown_job for a job it
                    // no longer has (its daemon restarted).
                    if matches!(
                        failure.0.get("code").and_then(Value::as_str),
                        Some("seed.bad_request" | "seed.unknown_job")
                    ) {
                        store::set_job(self.mux, session, name, None)?;
                    }
                    return Err(failure);
                }
            };
            // Progress shares the existing projection event. Bound writes to
            // once per second; completion always removes the running state.
            if status.get("state").and_then(Value::as_str) != Some("running")
                || last_progress.is_none_or(|at| at.elapsed() >= Duration::from_secs(1))
            {
                let mut saved =
                    json!({"job":job,"repo":repo,"ref":reference,"state":status.get("state")});
                for key in ["phase", "progress", "notes"] {
                    if let Some(value) = status.get(key) {
                        saved.set(key, value.clone());
                    }
                }
                store::set_job(self.mux, session, name, Some(&saved))?;
                last_progress = Some(Instant::now());
            }
            match status.get("state").and_then(Value::as_str) {
                Some("done") => {
                    let head = status
                        .get("head")
                        .and_then(Value::as_str)
                        .filter(|h| !h.is_empty())
                        .ok_or_else(transport_error)?;
                    let mut result =
                        json!({"state":"done","repo":repo,"folder":folder,"head":head});
                    if let Some(notes) = status.get("notes") {
                        result.set("notes", notes.clone());
                    }
                    return Ok(result);
                }
                Some("failed") => {
                    store::set_job(self.mux, session, name, None)?;
                    return Err(self.seed_failure(&status, repo)?);
                }
                Some("running") if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(250))
                }
                Some("running") => {
                    return Err(Failure::new(
                        "seed.clone_failed",
                        "Cloning is still running. Retry Add repository to resume waiting for the same clone.",
                    ));
                }
                _ => return Err(transport_error()),
            }
        }
    }
    fn record(&self, session: &str, attached: &Value) -> Result<(), Failure> {
        store::record(self.mux, session, attached)
    }
}

pub(crate) fn handle(mux: &Mux, cmd: &str, args: &Value) -> Value {
    let result = (|| {
        if cmd == "cloud.repo.local" {
            let mut result = super::local::local_catalog(mux).map_err(|_| {
                Failure::new("seed.bad_request", "Refresh the Mac's project list and retry.")
            })?;
            result.set(
                "recent",
                json!(
                    store::sources(mux)?
                        .into_iter()
                        .filter(|r| r.source == "recent")
                        .collect::<Vec<_>>()
                ),
            );
            return Ok(result);
        }
        if cmd == "cloud.repo.remember" {
            return store::remember(mux, args);
        }
        if crate::fs_ops::installed().is_none() {
            return Err(Failure::new(
                "seed.bad_request",
                "Open a chat on a Cloud machine, then retry Add repository.",
            ));
        }
        if cmd == "cloud.repo.sync" {
            return store::sync(mux, args);
        }
        let session = args
            .get("session")
            .and_then(Value::as_str)
            .filter(|s| super::engine::valid_name(s))
            .ok_or_else(|| {
                Failure::new("seed.bad_request", "Open a Cloud chat and retry with its chat ID.")
            })?;
        let home = std::env::var_os("HOME").map(PathBuf::from).ok_or_else(transport_error)?;
        let runtime = Runtime::new(mux, home);
        match cmd {
            "cloud.repo.list" => list(&runtime, args.get("query").and_then(Value::as_str)),
            "cloud.repo.add" => add(&runtime, args),
            "cloud.repo.attached" => Ok(
                json!({"repos":runtime.attached(session)?,"pending":store::pending(mux, session)?}),
            ),
            "cloud.repo.wait_github" => {
                let timeout =
                    args.get("timeout_ms").and_then(Value::as_u64).unwrap_or(30_000).min(60_000);
                runtime.wait_github(timeout)
            }
            _ => Err(Failure::new(
                "seed.bad_request",
                "Run `cmux cloud repo --help` and choose a supported repository action.",
            )),
        }
    })();
    result.unwrap_or_else(|e| e.0)
}

#[cfg(test)]
#[path = "runtime_tests.rs"]
mod tests;
