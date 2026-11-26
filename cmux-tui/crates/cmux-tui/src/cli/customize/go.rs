//! `cmux customize go pr:N`: the Go button of a visible-UI pull request. The
//! person tried the PR on (`cmux customize try pr:N`), looked at it in their own
//! cmux, and says go: the PR is marked merge-ready at exactly the head they
//! tried, and the fleet's landing (cmuxterm-hq next_autoland: `land-now` from a
//! labeler, newer than the head's last push, waives the review wait for that
//! head only; CI must still be green) lands it.
//!
//! Leo, 2026-11-25: "I can just be instantly looking at UI, like deciding
//! against them, and then just being like, have that one click merge ready, or
//! like one click readiness to merge, like the go button for that to happen."
//!
//! What Go does, signed in as the person through `gh`:
//! - refuses a PR they never tried here, or one pushed since (its head is not
//!   the one the library entry was built from): they saw other code;
//! - adds `land-now` and `ready-to-land`, takes off `needs a call` (the label a
//!   lane holds a visible-UI PR with until someone looks);
//! - comments the head it was given at, so the landing and the lane read it.
//!
//! A push after Go makes the label older than the head, so the landing waits
//! for another Go: Go never carries over to code nobody looked at.

use std::time::Duration;

use cmux_customize::Customize;
use serde_json::{Value, json};

use super::Failure;
use super::pr::{REPO, failure, is_sha, short};
use super::render::Answer;

/// What Go labels: autoland's force label (a labeler's, newer than the head)
/// and its ready label.
pub(super) const GO_LABELS: [&str; 2] = ["land-now", "ready-to-land"];
/// The label a lane holds a visible-UI PR with until the person looks.
pub(super) const LOOK_LABEL: &str = "needs a call";
/// How long one `gh` call may take.
const GH_LIMIT: Duration = Duration::from_secs(30);

/// One `gh` call: what it printed, or why not in gh's own words.
pub(super) type Gh<'a> = dyn FnMut(&[String]) -> Result<String, String> + 'a;

/// `go pr:N` with the signed-in `gh`.
pub(super) fn go(customize: &Customize, pr: u64) -> Result<Answer, Failure> {
    let mut gh = |args: &[String]| super::rebuild::gh(args, GH_LIMIT);
    go_with(customize, pr, &mut gh)
}

/// `go pr:N` with `gh` (tests pass their own).
pub(super) fn go_with(customize: &Customize, pr: u64, gh: &mut Gh<'_>) -> Result<Answer, Failure> {
    let library = customize.library()?;
    let tried = library
        .entries
        .iter()
        .filter_map(|entry| entry.code.as_ref())
        .find(|code| code.pr == pr && code.repo == REPO)
        .map(|code| code.head.clone())
        .filter(|head| is_sha(head))
        .ok_or_else(|| {
            failure(format!(
                "pr:{pr} was never tried on here: `cmux customize try pr:{pr}` first, then go"
            ))
        })?;
    let words = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    let said = gh(&words(&[
        "api",
        &format!("repos/{REPO}/pulls/{pr}"),
        "--jq",
        "{head: .head.sha, state: .state, merged: .merged, draft: .draft, title: .title, labels: [.labels[].name]}",
    ]))
    .map_err(|why| failure(format!("could not read pr:{pr} from GitHub: {why}")))?;
    let pull: Value = serde_json::from_str(said.trim())
        .map_err(|_| failure(format!("GitHub's answer for pr:{pr} did not read")))?;
    let head = pull["head"].as_str().unwrap_or_default().to_owned();
    if pull["merged"].as_bool() == Some(true) {
        return Err(failure(format!("pr:{pr} is merged already")));
    }
    if pull["state"].as_str() != Some("open") {
        return Err(failure(format!("pr:{pr} is closed")));
    }
    if head != tried {
        return Err(failure(format!(
            "pr:{pr} moved since you tried it (you saw {}, its head is {} now): \
             `cmux customize try pr:{pr}` again, then go",
            short(&tried),
            short(&head)
        )));
    }
    let login = gh(&words(&["api", "user", "--jq", ".login"]))
        .map(|login| login.trim().to_owned())
        .unwrap_or_default();
    let mut add = words(&["api", "-X", "POST", &format!("repos/{REPO}/issues/{pr}/labels")]);
    for label in GO_LABELS {
        add.extend(["-f".to_owned(), format!("labels[]={label}")]);
    }
    gh(&add).map_err(|why| failure(format!("could not mark pr:{pr} merge-ready: {why}")))?;
    let labels: Vec<&str> =
        pull["labels"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut lifted = false;
    if labels.iter().any(|label| label.eq_ignore_ascii_case(LOOK_LABEL)) {
        let name = LOOK_LABEL.replace(' ', "%20");
        lifted = gh(&words(&[
            "api",
            "-X",
            "DELETE",
            &format!("repos/{REPO}/issues/{pr}/labels/{name}"),
        ]))
        .is_ok();
    }
    let who = if login.is_empty() { "the person".to_owned() } else { format!("@{login}") };
    let body = format!(
        "Go at {head}: {who} tried this PR on in their cmux (`cmux customize try pr:{pr}`) and marked it \
         merge-ready. It lands at this head once CI is green; a push after this waits for another Go."
    );
    // The labels are the signal; the comment is the record. A comment that did
    // not post is said, not a failure.
    let commented = gh(&words(&[
        "api",
        "-X",
        "POST",
        &format!("repos/{REPO}/issues/{pr}/comments"),
        "-f",
        &format!("body={body}"),
    ]))
    .is_ok();
    let draft = pull["draft"].as_bool() == Some(true);
    let mut human = format!(
        "Go: pr:{pr} is merge-ready at {} ({}), it lands once CI is green\n",
        short(&head),
        GO_LABELS.join(", ")
    );
    if lifted {
        human.push_str(&format!("  took off {LOOK_LABEL:?}\n"));
    }
    if draft {
        human.push_str("  it is a draft: its lane marks it ready before it lands\n");
    }
    if !commented {
        human.push_str("  the Go comment did not post (the labels did)\n");
    }
    if !login.is_empty() {
        human.push_str(&format!("  as @{login}\n"));
    }
    Ok(Answer::Library {
        json: json!({
            "pr": pr,
            "repo": REPO,
            "head": head,
            "title": pull["title"],
            "labels": GO_LABELS,
            "lifted": lifted,
            "commented": commented,
            "draft": draft,
            "login": login,
        }),
        human,
    })
}

#[cfg(test)]
#[path = "go_tests.rs"]
mod tests;
