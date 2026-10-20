//! `cmux agent link` and `cmux agent artifacts` (manaflow-ai/cmuxterm-hq#2555).
//!
//! Provenance runs both ways. `agent link` prints the address of the agent
//! session this command runs in, in the forms an artifact carries: the
//! `cmux://agent/<harness>/<session>` link, its web fallback, the
//! `Agent-Session:` commit trailer and a PR-body line. `agent artifacts` goes
//! back the other way: the commits whose `Agent-Session:` trailer names a
//! session, and with `--github` the pull requests and CI runs of those commits.
//!
//! A link is an address, not a credential. It names a session; it never
//! carries an account, a working directory or anything that grants access.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// The trailer every agent commit carries (`git interpret-trailers`).
pub(super) const TRAILER_KEY: &str = "Agent-Session";
const NATIVE_PREFIX: &str = "cmux://agent/";
const WEB_PREFIX: &str = "https://cmux.com/deeplink/agent?";
/// The commits `agent artifacts` reads at most, newest first.
const MAX_COMMITS: usize = 200;
/// The CI runs `agent artifacts --github` lists per commit at most.
const RUNS_PER_COMMIT: usize = 20;

/// The environment variables that name the harness session, in order. They are
/// the ones each harness already exports (acpmux harness names).
const HARNESS_ENV: [(&str, &str); 4] = [
    ("CLAUDE_CODE_SESSION_ID", "claude"),
    ("CODEX_THREAD_ID", "codex"),
    ("CODEX_SESSION_ID", "codex"),
    ("OPENCODE_SESSION_ID", "opencode"),
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum ProvenancePlan {
    Link(LinkForm),
    Artifacts(ArtifactsPlan),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum LinkForm {
    Native,
    Web,
    Trailer,
    Footer,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ArtifactsPlan {
    /// `<harness>/<session>` or an agent link; nil for this environment's session.
    pub session: Option<String>,
    pub repo: Option<String>,
    pub github: bool,
}

/// Runs `cmux agent link|artifacts`; nil for any other command. Both are local
/// (no daemon), so they are answered before the daemon grammar.
pub(super) fn intercept(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let [scope, verb, rest @ ..] = words.as_slice() else { return None };
    if scope != "agent" || !matches!(verb.as_str(), "link" | "artifacts") {
        return None;
    }
    match parse(verb, rest) {
        Ok(plan) => Some(run(global, plan)),
        Err(error) => {
            let error = json!({"code": "usage.invalid", "message": format!("cmux: {}", error.0),
                "details": {}, "retryable": false});
            Some(super::wire::print_local_error(&error, global.output, 2))
        }
    }
}

/// The words after `agent link` or `agent artifacts`.
pub(super) fn parse(verb: &str, args: &[String]) -> Result<ProvenancePlan, UsageError> {
    let (mut positionals, mut flags, mut repo) = (Vec::new(), Vec::new(), None);
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.strip_prefix("--") {
            Some("repo") => {
                repo = Some(
                    words
                        .next()
                        .ok_or_else(|| UsageError::new("--repo needs a directory"))?
                        .clone(),
                )
            }
            Some(flag) => match flag.strip_prefix("repo=") {
                Some(dir) => repo = Some(dir.to_owned()),
                None => flags.push(flag),
            },
            None => positionals.push(word.as_str()),
        }
    }
    let known: &[&str] = if verb == "link" { &["web", "trailer", "footer"] } else { &["github"] };
    if let Some(flag) = flags.iter().find(|flag| !known.contains(flag)) {
        return Err(UsageError::new(format!("unknown flag --{flag} for agent {verb}")));
    }
    let has = |name: &str| flags.contains(&name);
    if verb == "link" {
        if repo.is_some() {
            return Err(UsageError::new("unknown flag --repo for agent link"));
        }
        return parse_link(&positionals, has("web"), has("trailer"), has("footer"));
    }
    parse_artifacts(&positionals, repo, has("github"))
}

/// `link [--web|--trailer|--footer]`.
pub(super) fn parse_link(
    rest: &[&str],
    web: bool,
    trailer: bool,
    footer: bool,
) -> Result<ProvenancePlan, UsageError> {
    if !rest.is_empty() {
        return Err(UsageError::new("usage: cmux agent link [--web|--trailer|--footer]"));
    }
    let form = match (web, trailer, footer) {
        (false, false, false) => LinkForm::Native,
        (true, false, false) => LinkForm::Web,
        (false, true, false) => LinkForm::Trailer,
        (false, false, true) => LinkForm::Footer,
        _ => {
            return Err(UsageError::new(
                "cmux agent link takes one of --web, --trailer or --footer",
            ));
        }
    };
    Ok(ProvenancePlan::Link(form))
}

/// `artifacts [<harness>/<session>|<agent link>] [--repo <dir>] [--github]`.
pub(super) fn parse_artifacts(
    rest: &[&str],
    repo: Option<String>,
    github: bool,
) -> Result<ProvenancePlan, UsageError> {
    let session = match rest {
        [] => None,
        [session] => {
            if AgentSession::parse(session).is_none() {
                return Err(UsageError::new(format!(
                    "`{session}` is not an agent session: give <harness>/<session> or a cmux://agent link"
                )));
            }
            Some((*session).to_owned())
        }
        _ => {
            return Err(UsageError::new(
                "usage: cmux agent artifacts [<harness>/<session>] [--repo <dir>] [--github]",
            ));
        }
    };
    Ok(ProvenancePlan::Artifacts(ArtifactsPlan { session, repo, github }))
}

/// A harness and the harness's own session id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct AgentSession {
    pub harness: String,
    pub session: String,
}

impl AgentSession {
    /// This environment's session: `CMUX_AGENT_SESSION_ID` (with
    /// `CMUX_AGENT_HARNESS`, default `cmux`), else the first harness variable set.
    pub(super) fn detect(env: &dyn Fn(&str) -> Option<String>) -> Option<Self> {
        let set = |key: &str| env(key).filter(|value| !value.is_empty());
        if let Some(session) = set("CMUX_AGENT_SESSION_ID") {
            let harness = set("CMUX_AGENT_HARNESS").unwrap_or_else(|| "cmux".into());
            return Some(Self { harness, session });
        }
        HARNESS_ENV.iter().find_map(|(key, harness)| {
            set(key).map(|session| Self { harness: (*harness).into(), session })
        })
    }

    /// `<harness>/<session>`, a `cmux://agent/<harness>/<session>` link (any
    /// `cmux-…` scheme) or the `https://cmux.com/deeplink/agent?…` fallback.
    pub(super) fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        if let Some(query) = text.strip_prefix(WEB_PREFIX) {
            let harness = query_value(query, "harness")?;
            let session = query_value(query, "session")?;
            return Self::checked(harness, session);
        }
        let path = match text.split_once("://") {
            Some((scheme, rest)) if scheme == "cmux" || scheme.starts_with("cmux-") => {
                rest.strip_prefix("agent/")?
            }
            Some(_) => return None,
            None => text,
        };
        let path = path.split(['?', '#']).next()?;
        let (harness, session) = path.split_once('/')?;
        Self::checked(percent_decode(harness)?, percent_decode(session)?)
    }

    fn checked(harness: String, session: String) -> Option<Self> {
        let harness_ok = (1..=64).contains(&harness.len())
            && harness
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');
        let session_ok = (1..=200).contains(&session.len())
            && session.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._~-".contains(&byte))
            && !session.bytes().all(|byte| byte == b'.');
        (harness_ok && session_ok).then_some(Self { harness, session })
    }
}

/// The session plus its display hints: the machine and the agent's name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Identity {
    pub session: AgentSession,
    pub host: String,
    pub name: Option<String>,
}

impl Identity {
    /// Host: `CMUX_AGENT_HOST`, else the short hostname. Name: `CMUX_AGENT_NAME`,
    /// else the lane part of `AGENT_LEASE_HOLDER` (`<lane>@<host>`).
    pub(super) fn detect(
        env: &dyn Fn(&str) -> Option<String>,
        hostname: &dyn Fn() -> String,
    ) -> Option<Self> {
        let session = AgentSession::detect(env)?;
        let set = |key: &str| env(key).filter(|value| !value.is_empty());
        let host = set("CMUX_AGENT_HOST")
            .unwrap_or_else(|| hostname().split('.').next().unwrap_or_default().to_owned());
        let name = set("CMUX_AGENT_NAME")
            .or_else(|| {
                set("AGENT_LEASE_HOLDER")
                    .map(|holder| holder.split('@').next().unwrap_or_default().to_owned())
            })
            .filter(|name| !name.is_empty());
        Some(Self { session, host, name })
    }

    fn hints(&self) -> Vec<(&'static str, &str)> {
        let mut hints = vec![("host", self.host.as_str())];
        if let Some(name) = &self.name {
            hints.push(("name", name.as_str()));
        }
        hints
    }

    pub(super) fn native_link(&self) -> String {
        format!(
            "{NATIVE_PREFIX}{}/{}?{}",
            percent_encode(&self.session.harness),
            percent_encode(&self.session.session),
            query(&self.hints())
        )
    }

    pub(super) fn web_link(&self) -> String {
        let mut params = vec![
            ("harness", self.session.harness.as_str()),
            ("session", self.session.session.as_str()),
        ];
        params.extend(self.hints());
        format!("{WEB_PREFIX}{}", query(&params))
    }

    pub(super) fn trailer(&self) -> String {
        format!("{TRAILER_KEY}: {}", self.web_link())
    }

    pub(super) fn footer(&self) -> String {
        let who = match &self.name {
            Some(name) => format!("{name} on {}", self.host),
            None => self.host.clone(),
        };
        let who: String = who
            .chars()
            .filter(|char| char.is_ascii_alphanumeric() || " ._@-".contains(*char))
            .collect();
        format!("Agent session: [{who}]({})", self.web_link())
    }
}

fn query(params: &[(&str, &str)]) -> String {
    params
        .iter()
        .map(|(key, value)| format!("{key}={}", percent_encode(value)))
        .collect::<Vec<_>>()
        .join("&")
}

fn query_value(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (name, value) = pair.split_once('=')?;
        (name == key).then(|| percent_decode(&value.replace('+', " "))).flatten()
    })
}

fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = text.get(index + 1..index + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// One commit whose `Agent-Session:` trailer names the session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Commit {
    pub sha: String,
    pub time: u64,
    pub subject: String,
}

/// Field and record separators of the `git log` format below.
const FIELD: char = '\u{1f}';
const RECORD: char = '\u{1e}';

/// The commits of `git log` output (`%H FIELD %ct FIELD %s FIELD trailers RECORD`)
/// with an `Agent-Session:` trailer that names `session`. Other commits that
/// merely mention the id in their text don't count.
pub(super) fn matching_commits(log: &str, session: &AgentSession) -> Vec<Commit> {
    log.split(RECORD)
        .filter_map(|record| {
            let mut fields = record.trim_start_matches('\n').splitn(4, FIELD);
            let sha = fields.next()?.trim();
            let time = fields.next()?.trim().parse().ok()?;
            let subject = fields.next()?;
            let trailers = fields.next()?;
            let names =
                trailers.lines().filter_map(AgentSession::parse).any(|found| &found == session);
            (names && !sha.is_empty()).then(|| Commit {
                sha: sha.to_owned(),
                time,
                subject: subject.to_owned(),
            })
        })
        .collect()
}

fn git_log(repo: &Path, session: &AgentSession) -> Result<String, String> {
    let format = format!(
        "--format=%H{FIELD}%ct{FIELD}%s{FIELD}%(trailers:key={TRAILER_KEY},valueonly,separator=%x0A){RECORD}"
    );
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["log", "--all", "--fixed-strings", &format!("--max-count={MAX_COMMITS}")])
        .arg(format!("--grep={}", session.session))
        .arg(format)
        .output()
        .map_err(|error| format!("cannot run git: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "git log failed in {}: {}",
            repo.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// `gh` with its JSON answer, run in the repository so `{owner}/{repo}` resolve.
fn gh(repo: &Path, args: &[&str]) -> Result<Value, String> {
    let output = Command::new("gh")
        .current_dir(repo)
        .args(args)
        .output()
        .map_err(|error| format!("cannot run gh: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "gh {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("gh {} answered no JSON: {error}", args.join(" ")))
}

/// The pull requests that contain the commits (each once, in first-seen order)
/// and every commit's CI runs.
fn github(repo: &Path, commits: &[Commit]) -> Result<(Vec<Value>, Vec<Value>), String> {
    let mut pulls: Vec<Value> = Vec::new();
    let mut runs = Vec::new();
    for commit in commits {
        let found =
            gh(repo, &["api", &format!("repos/{{owner}}/{{repo}}/commits/{}/pulls", commit.sha)])?;
        for pull in found.as_array().into_iter().flatten() {
            if pulls.iter().any(|seen| seen["number"] == pull["number"]) {
                continue;
            }
            pulls.push(json!({
                "number": pull["number"], "url": pull["html_url"], "state": pull["state"],
                "title": pull["title"], "merged_at": pull["merged_at"],
            }));
        }
        let limit = RUNS_PER_COMMIT.to_string();
        let found = gh(
            repo,
            &[
                "run",
                "list",
                "--commit",
                &commit.sha,
                "--limit",
                &limit,
                "--json",
                "databaseId,name,url,status,conclusion",
            ],
        )?;
        for run in found.as_array().into_iter().flatten() {
            runs.push(json!({
                "id": run["databaseId"], "name": run["name"], "url": run["url"], "status": run["status"],
                "conclusion": run["conclusion"], "sha": commit.sha,
            }));
        }
    }
    Ok((pulls, runs))
}

fn env_var(key: &str) -> Option<String> {
    std::env::var(key).ok()
}

fn hostname() -> String {
    Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .unwrap_or_default()
}

fn fail(global: &GlobalArgs, code: &str, message: String) -> i32 {
    let error = json!({"code": code, "message": message, "retryable": false});
    super::wire::print_local_error(&error, global.output, 1)
}

pub(super) fn run(global: GlobalArgs, plan: ProvenancePlan) -> i32 {
    match plan {
        ProvenancePlan::Link(form) => run_link(&global, form),
        ProvenancePlan::Artifacts(plan) => run_artifacts(&global, plan),
    }
}

fn no_session() -> String {
    "no agent session in this environment (CMUX_AGENT_SESSION_ID, CLAUDE_CODE_SESSION_ID, CODEX_THREAD_ID, \
     CODEX_SESSION_ID or OPENCODE_SESSION_ID)"
        .into()
}

fn run_link(global: &GlobalArgs, form: LinkForm) -> i32 {
    let Some(identity) = Identity::detect(&env_var, &hostname) else {
        return fail(global, "local.agent_session", no_session());
    };
    let text = match form {
        LinkForm::Native => identity.native_link(),
        LinkForm::Web => identity.web_link(),
        LinkForm::Trailer => identity.trailer(),
        LinkForm::Footer => identity.footer(),
    };
    let value = json!({
        "harness": identity.session.harness, "session": identity.session.session, "host": identity.host,
        "name": identity.name, "link": identity.native_link(), "web_link": identity.web_link(), "text": text,
    });
    match global.output {
        OutputMode::Human => {
            super::wire::print_local_success(&Value::String(text), OutputMode::Human)
        }
        output => super::wire::print_local_success(&value, output),
    }
}

fn run_artifacts(global: &GlobalArgs, plan: ArtifactsPlan) -> i32 {
    let session = match plan.session.as_deref() {
        Some(text) => AgentSession::parse(text),
        None => AgentSession::detect(&env_var),
    };
    let Some(session) = session else {
        return fail(
            global,
            "local.agent_session",
            format!("{}; pass <harness>/<session>", no_session()),
        );
    };
    let repo = plan.repo.map_or_else(|| PathBuf::from("."), PathBuf::from);
    let commits = match git_log(&repo, &session) {
        Ok(log) => matching_commits(&log, &session),
        Err(message) => return fail(global, "local.git", message),
    };
    let (pulls, runs) = if plan.github {
        match github(&repo, &commits) {
            Ok(found) => found,
            Err(message) => return fail(global, "local.github", message),
        }
    } else {
        (Vec::new(), Vec::new())
    };
    let link = format!(
        "{NATIVE_PREFIX}{}/{}",
        percent_encode(&session.harness),
        percent_encode(&session.session)
    );
    let value = json!({
        "harness": session.harness, "session": session.session, "link": link,
        "commits": commits.iter().map(|commit| json!({"sha": commit.sha, "time": commit.time, "subject": commit.subject})).collect::<Vec<_>>(),
        "pull_requests": pulls, "runs": runs, "github": plan.github,
    });
    match global.output {
        OutputMode::Human => {
            super::wire::print_local_success(&Value::String(human(&value)), OutputMode::Human)
        }
        output => super::wire::print_local_success(&value, output),
    }
}

fn text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => "-".into(),
        other => other.to_string(),
    }
}

fn human(value: &Value) -> String {
    let list = |key: &str| value[key].as_array().cloned().unwrap_or_default();
    let mut out = format!("{}\n", text(&value["link"]));
    let commits = list("commits");
    out.push_str(&format!("commits ({})\n", commits.len()));
    for commit in &commits {
        let sha = text(&commit["sha"]);
        out.push_str(&format!("  {}  {}\n", &sha[..sha.len().min(12)], text(&commit["subject"])));
    }
    if value["github"] == true {
        let pulls = list("pull_requests");
        out.push_str(&format!("pull requests ({})\n", pulls.len()));
        for pull in &pulls {
            out.push_str(&format!(
                "  #{} {}  {}\n",
                text(&pull["number"]),
                text(&pull["state"]),
                text(&pull["url"])
            ));
        }
        let runs = list("runs");
        out.push_str(&format!("runs ({})\n", runs.len()));
        for run in &runs {
            let result = if run["conclusion"].as_str().is_some_and(|value| !value.is_empty()) {
                &run["conclusion"]
            } else {
                &run["status"]
            };
            out.push_str(&format!(
                "  {} {}  {}\n",
                text(result),
                text(&run["name"]),
                text(&run["url"])
            ));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| pairs.iter().find(|(name, _)| *name == key).map(|(_, value)| (*value).to_owned())
    }

    #[test]
    fn the_session_comes_from_the_harness_environment() {
        let claude = AgentSession::detect(&env(&[("CLAUDE_CODE_SESSION_ID", "abc-1")])).unwrap();
        assert_eq!(claude, AgentSession { harness: "claude".into(), session: "abc-1".into() });
        let codex =
            AgentSession::detect(&env(&[("CODEX_THREAD_ID", "t-9"), ("OPENCODE_SESSION_ID", "o")]))
                .unwrap();
        assert_eq!(codex.harness, "codex");
        let cmux = AgentSession::detect(&env(&[
            ("CMUX_AGENT_SESSION_ID", "s"),
            ("CLAUDE_CODE_SESSION_ID", "c"),
        ]))
        .unwrap();
        assert_eq!(cmux, AgentSession { harness: "cmux".into(), session: "s".into() });
        assert_eq!(AgentSession::detect(&env(&[("CLAUDE_CODE_SESSION_ID", "")])), None);
    }

    #[test]
    fn links_match_the_deep_link_grammar_and_parse_back() {
        let identity = Identity::detect(
            &env(&[
                ("CLAUDE_CODE_SESSION_ID", "0f3c-7d4e"),
                ("AGENT_LEASE_HOLDER", "Lanternfish@build-mac.lan"),
            ]),
            &|| "build-mac.example.net".into(),
        )
        .unwrap();
        assert_eq!(
            identity.native_link(),
            "cmux://agent/claude/0f3c-7d4e?host=build-mac&name=Lanternfish"
        );
        assert_eq!(
            identity.web_link(),
            "https://cmux.com/deeplink/agent?harness=claude&session=0f3c-7d4e&host=build-mac&name=Lanternfish"
        );
        assert_eq!(identity.trailer(), format!("Agent-Session: {}", identity.web_link()));
        assert_eq!(
            identity.footer(),
            format!("Agent session: [Lanternfish on build-mac]({})", identity.web_link())
        );
        for text in [identity.native_link(), identity.web_link(), "claude/0f3c-7d4e".into()] {
            assert_eq!(AgentSession::parse(&text), Some(identity.session.clone()), "{text}");
        }
        assert_eq!(
            AgentSession::parse("cmux-dev://agent/claude/0f3c-7d4e").unwrap().session,
            "0f3c-7d4e"
        );
    }

    #[test]
    fn malformed_addresses_are_refused() {
        for text in [
            "claude",
            "Claude/x",
            "claude/..",
            "https://evil.example/agent/claude/x",
            "ssh://agent/claude/x",
            "claude/a b",
        ] {
            assert_eq!(AgentSession::parse(text), None, "{text}");
        }
    }

    #[test]
    fn only_a_trailer_naming_the_session_counts() {
        let session = AgentSession { harness: "claude".into(), session: "abc".into() };
        let trailer = "https://cmux.com/deeplink/agent?harness=claude&session=abc&host=m";
        let log = format!(
            "{a}{FIELD}10{FIELD}mine{FIELD}{trailer}\n{RECORD}\n\
             {b}{FIELD}9{FIELD}mentions abc{FIELD}{RECORD}\n\
             {c}{FIELD}8{FIELD}codex's{FIELD}https://cmux.com/deeplink/agent?harness=codex&session=abc&host=m\n{RECORD}\n\
             {d}{FIELD}7{FIELD}native{FIELD}other\ncmux://agent/claude/abc?host=m\n{RECORD}\n",
            a = "a".repeat(40),
            b = "b".repeat(40),
            c = "c".repeat(40),
            d = "d".repeat(40),
        );
        let found = matching_commits(&log, &session);
        assert_eq!(
            found.iter().map(|commit| commit.subject.as_str()).collect::<Vec<_>>(),
            ["mine", "native"]
        );
        assert_eq!(found[0].time, 10);
    }
}
