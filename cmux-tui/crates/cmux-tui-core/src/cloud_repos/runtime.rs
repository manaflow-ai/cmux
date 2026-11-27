//! Bounded I/O adapters. Clone work goes only through git-seed-v1; no git
//! clone process, credentials or second seed implementation lives here.
use super::{Backend, Catalog, Failure, Repo, add, list, store};
use crate::Mux;
use crate::retry::{Attempt, Patience};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const AGENT_SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
const IO_TIMEOUT: Duration = Duration::from_secs(20);
const CLONE_TIMEOUT: Duration = Duration::from_secs(9 * 60);
const MAX_REPLY: u64 = 4 * 1024 * 1024;
static ADDS: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();

/// How long a socket still coming up (the agent or the daemon restarting) is waited for.
#[cfg(not(test))]
const CONNECT_PATIENCE: Duration = Duration::from_secs(10);
#[cfg(test)]
const CONNECT_PATIENCE: Duration = Duration::from_millis(300);
/// How long one page of GitHub's repository list waits out a transient refusal (the agent busy
/// or not bound yet, cmux Cloud out of reach, a short rate limit). The agent waits too.
#[cfg(not(test))]
const REPOS_PATIENCE: Duration = Duration::from_secs(15);
#[cfg(test)]
const REPOS_PATIENCE: Duration = Duration::from_millis(600);

fn transport_error() -> Failure {
    Failure::new(
        "seed.clone_failed",
        "The Cloud machine's repository service did not answer; check that the machine is running.",
    )
}
fn socket_request(path: &Path, request: &Value) -> Result<Value, Failure> {
    // Nothing is sent before the connect, so a socket that is not up yet is waited for; once
    // a request is sent it is never repeated here (a seed start must not run twice).
    let mut socket = Patience::new("the Cloud machine's agent", CONNECT_PATIENCE)
        .quiet()
        .run(|| {
            UnixStream::connect(path).map_err(|error| match error.kind() {
                ErrorKind::NotFound
                | ErrorKind::ConnectionRefused
                | ErrorKind::WouldBlock
                | ErrorKind::Interrupted => Attempt::Retry(error),
                _ => Attempt::Fail(error),
            })
        })
        .map_err(|_| transport_error())?;
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
            if catalog.disconnected {
                let url = catalog.install_url.ok_or_else(super::engine::install_link_required)?;
                failure = Failure::needs_github(&url);
            } else {
                let url = self.optional_install_url(value)?;
                failure = Failure::new(
                    "repo.no_access",
                    "Install GitHub access for this organization, or request access from its owner.",
                );
                if let Some((org, _)) = repo.split_once('/') {
                    failure.0.set("org", json!(org));
                }
                if let Some(url) = url {
                    failure.0.set("install_url", json!(url));
                }
            }
        } else if failure.0.get("code").and_then(Value::as_str) == Some("repo.no_access")
            && let Some(url) = self.optional_install_url(value)?
        {
            failure.0.set("install_url", json!(url));
        }
        Ok(failure)
    }

    fn wait_github(&self, timeout_ms: u64) -> Result<Value, Failure> {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms.min(60_000));
        loop {
            if !self.connector(None)?.disconnected {
                return Ok(json!({"connected":true}));
            }
            if Instant::now() >= deadline {
                return Ok(json!({"connected":false}));
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    /// One page of the agent's `github_repos`, asked again through a refusal a later ask can
    /// pass (it is a read): the agent busy or not bound yet, cmux Cloud out of reach, GitHub
    /// failing, or a rate limit whose `retry_after` fits the wait. The last answer otherwise.
    fn repos_page(&self, ask: Value) -> Result<Value, Failure> {
        let request = json!({"github_repos": ask});
        let mut patience = Patience::new("GitHub's repository list", REPOS_PATIENCE).quiet();
        loop {
            let answer = socket_request(&self.agent_socket, &request)?;
            let error = answer.get("error").filter(|_| answer.get("ok") == Some(&json!(false)));
            let transient = error.is_some_and(|error| {
                error.get("retryable") == Some(&json!(true))
                    // Agents from before `retryable`.
                    || matches!(
                        error.get("code").and_then(Value::as_str),
                        Some(
                            "busy"
                                | "vm.unbound"
                                | "integration.unreachable"
                                | "integration.unavailable"
                                | "rate_limited"
                        )
                    )
            });
            let after = answer.get("retry_after").and_then(Value::as_u64).map(Duration::from_secs);
            if !transient || !patience.sleep(after) {
                return Ok(answer);
            }
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
}
impl Backend for Runtime<'_> {
    fn sources(&self) -> Result<Vec<Repo>, Failure> {
        store::sources(self.mux)
    }
    fn connector(&self, query: Option<&str>) -> Result<Catalog, Failure> {
        let mut cursor: Option<String> = None;
        let mut seen = HashSet::new();
        let mut catalog = Catalog::default();
        // A selection that changed mid-listing restarts from the first page, once.
        let mut restarted = false;
        let deadline = Instant::now() + Duration::from_secs(45);
        // A repeated cursor is an upstream error, never an infinite scan.
        for _ in 0..100 {
            if Instant::now() >= deadline {
                return Err(Failure::new(
                    "seed.clone_failed",
                    "Repository discovery took over 45 seconds. Narrow the repository search.",
                ));
            }
            let mut ask = json!({});
            if let Some(q) = query {
                ask.set("query", json!(q));
            }
            if let Some(c) = &cursor {
                ask.set("cursor", json!(c));
            }
            let answer = self.repos_page(ask)?;
            if answer.get("ok").and_then(Value::as_bool) != Some(true) {
                let error = answer.get("error").unwrap_or(&Value::Null);
                let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
                if code == "repo.needs_github" {
                    // Missing installation is the same recoverable state
                    // whether the bridge returns connect or a typed error.
                    // Keep repositories already received from earlier pages:
                    // an installation can expire while a paginated catalog
                    // is being read, but those rows are still valid choices.
                    return Ok(Catalog {
                        repos: catalog.repos,
                        install_url: self.optional_install_url(error)?,
                        disconnected: true,
                    });
                }
                if code == "cursor_stale" && !restarted {
                    restarted = true;
                    (cursor, catalog) = (None, Catalog::default());
                    seen.clear();
                    continue;
                }
                let mut failure = if code == "repo.no_access" {
                    Failure::new(
                        code,
                        "Install GitHub access for the repository's organization, or request access from its owner.",
                    )
                } else {
                    // The agent's own message names the cause (`cmux-host` `github_repos.rs`).
                    let message = error
                        .get("message")
                        .and_then(Value::as_str)
                        .filter(|m| !m.is_empty() && m.len() <= 300 && !m.chars().any(char::is_control))
                        .map_or_else(
                            || "GitHub repository discovery failed on this Cloud machine. Reconnecting GitHub from Add repository renews its link.".to_owned(),
                            |m| format!("GitHub repository discovery failed: {m}"),
                        );
                    Failure::new("seed.clone_failed", &message)
                };
                if code == "repo.no_access"
                    && let Some(url) = self.optional_install_url(error)?
                {
                    failure.0.set("install_url", json!(url));
                }
                if let Some(after) = answer.get("retry_after").filter(|v| v.is_u64()) {
                    failure.0.set("retry_after", after.clone());
                }
                return Err(failure);
            }
            if let Some(connect) = answer.get("connect").filter(|v| v.is_object()) {
                catalog.disconnected = true;
                catalog.install_url = self.optional_install_url(connect)?;
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
        Err(Failure::new(
            "seed.bad_request",
            "The repository list runs past 100 pages. Narrow the repository search.",
        ))
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
        // The same add already running: wait for it (bounded by its own clone deadline), then
        // answer with its result below instead of refusing this one.
        let _guard = lock.lock().unwrap_or_else(|e| e.into_inner());
        // A second call may have resolved before the first one recorded its result.
        if let Some(existing) = self.attached(session)?.into_iter().find(|r| {
            r.get("repo").and_then(Value::as_str).is_some_and(|r| r.eq_ignore_ascii_case(repo))
        }) {
            return Ok(existing);
        }
        let existing = match store::job(self.mux, session, name)? {
            None => None,
            Some(existing) => {
                if existing.get("repo").and_then(Value::as_str) != Some(repo)
                    || existing.get("ref").unwrap_or(&Value::Null) != &json!(reference)
                {
                    return Err(Failure::new(
                        "seed.folder_not_empty",
                        "Choose a different chat for this repository or branch; another add already uses that folder.",
                    ));
                }
                match existing.get("completed").cloned() {
                    // The seed job can expire after clone completion. Retain its
                    // result until attachment recording succeeds, so recovery
                    // never tries to clone over the completed repository.
                    Some(completed) if !stale_result(&completed, repo, &folder) => {
                        return Ok(completed);
                    }
                    Some(_) => {
                        // The machine may have restarted with a stale projection
                        // entry. Drop only the metadata: the clone directory is
                        // user data and must remain untouched. A fresh seed job
                        // starts below, as a new add would.
                        store::set_job(self.mux, session, name, None)?;
                        None
                    }
                    None => Some(existing),
                }
            }
        };
        let start = || -> Result<String, Failure> {
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
            Ok(job)
        };
        let mut job = match existing {
            Some(existing) => {
                existing.get("job").and_then(Value::as_str).ok_or_else(transport_error)?.to_owned()
            }
            None => start()?,
        };
        // A job the seed daemon lost (it restarted) is started afresh once, here.
        let mut restarted = false;
        let deadline = Instant::now() + CLONE_TIMEOUT;
        let mut last_progress: Option<Instant> = None;
        loop {
            let status = match self.seed("git.seed.status", json!({"job":job}), repo) {
                Ok(status) => status,
                Err(failure) => {
                    // An expired/unknown job needs a fresh start; transport
                    // failures retain it to avoid a duplicate clone.
                    // git-seed-v1 answers seed.unknown_job for a job it
                    // no longer has (its daemon restarted).
                    if matches!(
                        failure.0.get("code").and_then(Value::as_str),
                        Some("seed.bad_request" | "seed.unknown_job")
                    ) {
                        store::set_job(self.mux, session, name, None)?;
                        if !restarted {
                            restarted = true;
                            job = start()?;
                            continue;
                        }
                    }
                    return Err(failure);
                }
            };
            // Progress shares the existing projection event. Bound writes to
            // once per second; completion always removes the running state.
            if status.get("state").and_then(Value::as_str) == Some("running")
                && last_progress.is_none_or(|at| at.elapsed() >= Duration::from_secs(1))
            {
                let mut saved =
                    json!({"job":job,"repo":repo,"ref":reference,"state":status.get("state")});
                for key in ["phase", "progress", "notes", "mirror"] {
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
                    for key in ["notes", "mirror"] {
                        if let Some(value) = status.get(key) {
                            result.set(key, value.clone());
                        }
                    }
                    store::set_job(
                        self.mux,
                        session,
                        name,
                        Some(&json!({
                            "job":job,"repo":repo,"ref":reference,"state":"done","completed":result
                        })),
                    )?;
                    return Ok(result);
                }
                Some("failed") => {
                    store::set_job(self.mux, session, name, None)?;
                    return Err(self.seed_failure(&status, repo)?);
                }
                Some("running") if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(250));
                }
                Some("running") => {
                    // The saved job is kept: the same add resumes waiting on it, and the
                    // caller may send it again by itself (`retryable`, `retry`).
                    let mut failure = Failure::new(
                        "seed.clone_failed",
                        "Cloning is still running on the Cloud machine after 9 minutes; it continues there, and adding the same repository waits for it instead of cloning again.",
                    );
                    let mut args = json!({"session":session,"repo":repo});
                    if let Some(reference) = reference {
                        args.set("ref", json!(reference));
                    }
                    failure.0.set("retryable", json!(true));
                    failure.0.set("retry", json!({"action":"cloud.repo.add","args":args}));
                    return Err(failure);
                }
                _ => return Err(transport_error()),
            }
        }
    }
    fn record(&self, session: &str, attached: &Value) -> Result<(), Failure> {
        store::record(self.mux, session, attached)
    }
}

/// Whether a saved clone result no longer matches its add: another repository or folder, not
/// done, or no head (a stale projection entry after a machine restart).
fn stale_result(completed: &Value, repo: &str, folder: &Path) -> bool {
    completed.get("repo").and_then(Value::as_str) != Some(repo)
        || completed.get("folder") != Some(&json!(folder))
        || completed.get("state").and_then(Value::as_str) != Some("done")
        || completed.get("head").and_then(Value::as_str).is_none_or(|head| head.is_empty())
}

pub(crate) fn handle(mux: &Mux, cmd: &str, args: &Value) -> Value {
    let result = (|| {
        if cmd == "cloud.repo.local" {
            let mut result = super::local::local_catalog(mux).map_err(|_| {
                Failure::new("seed.bad_request", "cmux could not read this Mac's project list.")
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
                "Open a chat on a Cloud machine to add a repository to it.",
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
                Failure::new("seed.bad_request", "Pass the chat ID of an open Cloud chat.")
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
