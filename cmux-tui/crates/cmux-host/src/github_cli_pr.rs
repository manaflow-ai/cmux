//! `cmux github pr create|view|comment`: pull requests through the platform edge, with no
//! GitHub token in the guest.
//!
//! On a Cloud machine whose platform edge is on, `platform.cmux.internal` resolves and the
//! machine's edge rule adds the machine's own authorization to every call to it. The platform
//! forwards `/v1/cloud/github/api/repos/OWNER/REPO/{pulls,issues}[/...]` to api.github.com with a
//! token it mints for that one repository and never sends here (cmux-platform
//! `GitHubApiEgress.ts`). This client sends no credential of its own: there is none on the
//! machine to send.
//!
//! The image's `gh` shim (`cmux github gh --auto`) sends `gh pr create` here on such a machine,
//! so an agent's plain `gh pr create` opens the PR the same way.

use std::net::ToSocketAddrs;

use cmux_server::cloud_http::JsonPoster;
use serde_json::{Value, json};

use crate::cloud::github::valid_repo;

/// The platform edge's name on a Cloud machine; it resolves only where the edge is on.
pub const EDGE_HOST: &str = "platform.cmux.internal";
/// The platform edge's origin.
pub const EDGE_ORIGIN: &str = "https://platform.cmux.internal";
/// The GitHub REST route under [`EDGE_ORIGIN`].
pub const API_PREFIX: &str = "/v1/cloud/github/api";

pub const PR_USAGE: &str = "usage: cmux github pr create [--repo OWNER/NAME] [--head BRANCH] [--base BRANCH] --title T [--body B | --body-file F] [--draft]\n       cmux github pr view NUMBER [--repo OWNER/NAME]\n       cmux github pr comment NUMBER --body B [--repo OWNER/NAME]";

/// Whether this machine's platform edge is on: its name resolves.
pub fn edge_available() -> bool {
    (EDGE_HOST, 443).to_socket_addrs().is_ok_and(|mut addrs| addrs.next().is_some())
}

/// One `pr create`: GitHub's create-pull-request body and the repository it is for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatePr {
    pub repo: String,
    pub head: String,
    pub base: String,
    pub title: String,
    pub body: String,
    pub draft: bool,
}

impl CreatePr {
    pub fn payload(&self) -> Value {
        let mut body = json!({
            "title": self.title,
            "head": self.head,
            "base": self.base,
            "body": self.body,
        });
        if self.draft {
            body["draft"] = Value::Bool(true);
        }
        body
    }
}

/// Where a `pr` verb's defaults come from: the checkout it runs in.
pub struct PrDefaults<'a> {
    pub repo: &'a dyn Fn() -> Option<String>,
    pub head: &'a dyn Fn() -> Option<String>,
    pub base: &'a dyn Fn() -> Option<String>,
    pub read_file: &'a dyn Fn(&str) -> Result<String, String>,
}

fn take_value<'a>(
    flag: &str,
    it: &mut impl Iterator<Item = &'a String>,
) -> Result<&'a String, String> {
    it.next().ok_or_else(|| format!("{flag} needs a value"))
}

/// The flags `pr create` takes, in `gh pr create`'s spelling (so the gh shim passes them as
/// given). Unknown flags are an error, never ignored.
pub fn parse_create(args: &[String], defaults: &PrDefaults<'_>) -> Result<CreatePr, String> {
    let (mut repo, mut head, mut base, mut title, mut body) = (None, None, None, None, None);
    let mut draft = false;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v.to_owned())),
            _ => (arg.as_str(), None),
        };
        let mut value = |it: &mut std::slice::Iter<'_, String>| -> Result<String, String> {
            match &inline {
                Some(v) => Ok(v.clone()),
                None => take_value(flag, it).cloned(),
            }
        };
        match flag {
            "--repo" | "-R" => repo = Some(value(&mut it)?),
            "--head" | "-H" => head = Some(value(&mut it)?),
            "--base" | "-B" => base = Some(value(&mut it)?),
            "--title" | "-t" => title = Some(value(&mut it)?),
            "--body" | "-b" => body = Some(value(&mut it)?),
            "--body-file" | "-F" => {
                let path = value(&mut it)?;
                body = Some((defaults.read_file)(&path)?);
            }
            "--draft" | "-d" => draft = true,
            other => return Err(format!("pr create: unknown argument {other}")),
        }
    }
    let repo = match repo {
        Some(r) => crate::github_cli::repo_from(&r)
            .ok_or_else(|| format!("not a GitHub repository: {r}"))?,
        None => (defaults.repo)().ok_or("no GitHub repository here: pass --repo OWNER/NAME")?,
    };
    if !valid_repo(&repo) {
        return Err(format!("not a GitHub repository: {repo}"));
    }
    let head =
        head.or_else(|| (defaults.head)()).ok_or("no branch checked out: pass --head BRANCH")?;
    let base =
        base.or_else(|| (defaults.base)()).ok_or("no default branch known: pass --base BRANCH")?;
    let title = title.filter(|t| !t.trim().is_empty()).ok_or("pr create needs --title")?;
    Ok(CreatePr { repo, head, base, title, body: body.unwrap_or_default(), draft })
}

/// The route for `repos/REPO/KIND[/rest]` on `origin`.
pub fn route(origin: &str, repo: &str, tail: &str) -> String {
    format!("{}{API_PREFIX}/repos/{repo}/{tail}", origin.trim_end_matches('/'))
}

/// GitHub's or the platform's error text from a non-2xx answer.
pub fn error_text(status: u16, body: &Value) -> String {
    let platform = body.pointer("/error/message").and_then(Value::as_str);
    let github = body.get("message").and_then(Value::as_str);
    let details = body
        .get("errors")
        .and_then(Value::as_array)
        .map(|errs| {
            errs.iter()
                .filter_map(|e| e.get("message").and_then(Value::as_str).or_else(|| e.as_str()))
                .collect::<Vec<_>>()
                .join("; ")
        })
        .filter(|s| !s.is_empty());
    let mut text = platform.or(github).unwrap_or("no message").to_owned();
    if let Some(details) = details {
        text = format!("{text}: {details}");
    }
    let hint = match status {
        404 if platform.is_some() => {
            " (the platform edge passes only repos/OWNER/NAME/pulls and issues calls)"
        }
        403 | 404 => " (is the cmux GitHub App installed on this repository?)",
        _ => "",
    };
    format!("GitHub answered {status}: {text}{hint}")
}

/// One call through the edge: `(status, body)`.
pub type Send<'a> = dyn Fn(&str, &str, Option<&Value>) -> Result<(u16, Value), String> + 'a;

/// Opens the pull request; its URL on success.
pub fn create(pr: &CreatePr, origin: &str, send: &Send<'_>) -> Result<String, String> {
    let url = route(origin, &pr.repo, "pulls");
    let (status, body) = send("POST", &url, Some(&pr.payload()))
        .map_err(|e| format!("the platform edge did not answer: {e}"))?;
    if !(200..300).contains(&status) {
        return Err(error_text(status, &body));
    }
    body.get("html_url")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| format!("GitHub answered {status} without the pull request's URL"))
}

fn number(raw: Option<&String>) -> Result<u64, String> {
    let raw = raw.ok_or("needs the pull request's NUMBER")?;
    let digits = raw.trim_start_matches('#');
    digits
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| format!("not a pull request number: {raw}"))
}

/// `pr view N` and `pr comment N --body B`: their NUMBER, repository and (comment) body.
pub fn parse_numbered(
    verb: &str,
    args: &[String],
    defaults: &PrDefaults<'_>,
) -> Result<(u64, String, Option<String>), String> {
    let mut positional = None;
    let (mut repo, mut body) = (None, None);
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--repo" | "-R" => repo = Some(take_value(arg, &mut it)?.clone()),
            "--body" | "-b" if verb == "comment" => body = Some(take_value(arg, &mut it)?.clone()),
            "--body-file" | "-F" if verb == "comment" => {
                body = Some((defaults.read_file)(take_value(arg, &mut it)?)?);
            }
            flag if flag.starts_with('-') => {
                return Err(format!("pr {verb}: unknown argument {flag}"));
            }
            _ if positional.is_none() => positional = Some(arg),
            other => return Err(format!("pr {verb}: unexpected argument {other}")),
        }
    }
    let n = number(positional)?;
    let repo = match repo {
        Some(r) => crate::github_cli::repo_from(&r)
            .ok_or_else(|| format!("not a GitHub repository: {r}"))?,
        None => (defaults.repo)().ok_or("no GitHub repository here: pass --repo OWNER/NAME")?,
    };
    if verb == "comment" && body.as_deref().is_none_or(|b| b.trim().is_empty()) {
        return Err("pr comment needs --body".into());
    }
    Ok((n, repo, body))
}

/// `pr view`: number, state, title and URL, one per line.
pub fn view(repo: &str, n: u64, origin: &str, send: &Send<'_>) -> Result<String, String> {
    let (status, body) = send("GET", &route(origin, repo, &format!("pulls/{n}")), None)
        .map_err(|e| format!("the platform edge did not answer: {e}"))?;
    if !(200..300).contains(&status) {
        return Err(error_text(status, &body));
    }
    let s = |k: &str| body.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    let state = if body.get("merged_at").is_some_and(|m| !m.is_null()) {
        "merged".into()
    } else {
        s("state")
    };
    Ok(format!("#{n} {state} {}\n{}", s("title"), s("html_url")))
}

/// `pr comment`: the comment's URL.
pub fn comment(
    repo: &str,
    n: u64,
    text: &str,
    origin: &str,
    send: &Send<'_>,
) -> Result<String, String> {
    let url = route(origin, repo, &format!("issues/{n}/comments"));
    let (status, body) = send("POST", &url, Some(&json!({ "body": text })))
        .map_err(|e| format!("the platform edge did not answer: {e}"))?;
    if !(200..300).contains(&status) {
        return Err(error_text(status, &body));
    }
    Ok(body.get("html_url").and_then(Value::as_str).unwrap_or("").to_owned())
}

fn git_line(args: &[&str]) -> Option<String> {
    let out = std::process::Command::new("git").args(args).output().ok()?;
    let line = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    (out.status.success() && !line.is_empty()).then_some(line)
}

fn checkout_repo() -> Option<String> {
    std::env::var("GH_REPO")
        .ok()
        .and_then(|r| crate::github_cli::repo_from(&r))
        .or_else(|| crate::github_cli::origin_url().and_then(|u| crate::github_cli::repo_from(&u)))
}

fn checkout_head() -> Option<String> {
    git_line(&["symbolic-ref", "--quiet", "--short", "HEAD"])
}

fn checkout_base() -> Option<String> {
    git_line(&["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        .map(|r| r.strip_prefix("origin/").map_or(r.clone(), str::to_owned))
}

fn read_file(path: &str) -> Result<String, String> {
    if path == "-" {
        let mut text = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin(), &mut text)
            .map_err(|e| format!("stdin: {e}"))?;
        return Ok(text);
    }
    std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))
}

/// The checkout's defaults, for [`run_with`].
pub fn checkout_defaults() -> PrDefaults<'static> {
    PrDefaults {
        repo: &checkout_repo,
        head: &checkout_head,
        base: &checkout_base,
        read_file: &read_file,
    }
}

/// `pr VERB ARGS` against `origin` with `send`; the line to print, or the error.
pub fn run_with(
    args: &[String],
    defaults: &PrDefaults<'_>,
    origin: &str,
    send: &Send<'_>,
) -> Result<String, String> {
    let Some((verb, rest)) = args.split_first() else { return Err(PR_USAGE.into()) };
    match verb.as_str() {
        "create" => create(&parse_create(rest, defaults)?, origin, send),
        "view" => {
            let (n, repo, _) = parse_numbered("view", rest, defaults)?;
            view(&repo, n, origin, send)
        }
        "comment" => {
            let (n, repo, body) = parse_numbered("comment", rest, defaults)?;
            comment(&repo, n, body.as_deref().unwrap_or_default(), origin, send)
        }
        "--help" | "-h" | "help" => Ok(PR_USAGE.into()),
        other => Err(format!("unknown pr verb {other}\n{PR_USAGE}")),
    }
}

/// Entry for `cmux github pr ARGS`.
pub fn run(args: &[String]) -> u8 {
    if !matches!(args.first().map(String::as_str), Some("--help" | "-h" | "help") | None)
        && !edge_available()
    {
        eprintln!(
            "cmux github pr: {EDGE_HOST} does not resolve, so this machine has no platform edge; use gh (cmux github gh) here"
        );
        return 1;
    }
    let poster = match JsonPoster::new() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cmux github pr: {e}");
            return 1;
        }
    };
    // No bearer: the edge rule adds the machine's own authorization; there is none here.
    let send = |method: &str, url: &str, body: Option<&Value>| poster.send(method, url, body, None);
    match run_with(args, &checkout_defaults(), EDGE_ORIGIN, &send) {
        Ok(line) => {
            println!("{line}");
            0
        }
        Err(e) => {
            eprintln!("cmux github pr: {e}");
            1
        }
    }
}

/// `gh pr create ...` as `cmux github pr create ...` when every flag is one this client takes;
/// `None` otherwise (gh runs as it would have).
pub fn from_gh(args: &[String]) -> Option<Vec<String>> {
    let rest = args.strip_prefix(&["pr".to_owned(), "create".to_owned()][..])?;
    let mut out = vec!["create".to_owned()];
    out.extend(rest.iter().cloned());
    let check = PrDefaults {
        repo: &|| Some("o/r".into()),
        head: &|| Some("h".into()),
        base: &|| Some("b".into()),
        read_file: &|_| Ok(String::new()),
    };
    parse_create(&out[1..], &check).ok().map(|_| out)
}

#[cfg(test)]
#[path = "github_cli_pr_tests.rs"]
mod tests;
