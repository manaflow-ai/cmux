//! `cmux customize library expire`: every experiment layer past its bound
//! off, with GitHub asked which PRs that are on merged or closed. The model
//! is `cmux_customize::library::expire`.

use std::time::{Duration, Instant};

use cmux_customize::Customize;
use cmux_customize::library::CodeKind;
use serde_json::{Value, json};

use super::Failure;
use super::render::Answer;

/// How long `run` waits for GitHub about one PR, and about all of them: the
/// app gives the whole run 30 s (`BundledCLIRun`).
const ASK_ONE: Duration = Duration::from_secs(5);
const ASK_ALL: Duration = Duration::from_secs(15);

/// `merged` or `closed` when GitHub says the PR is no longer open; `None`
/// while it is, or when GitHub does not answer.
fn ended(http: &super::pr::Http, repo: &str, pr: u64) -> Option<String> {
    let value =
        http.get_json(&format!("https://api.github.com/repos/{repo}/pulls/{pr}")).ok()??;
    (value.get("state").and_then(Value::as_str) == Some("closed")).then(|| {
        if value.get("merged").and_then(Value::as_bool) == Some(true) { "merged" } else { "closed" }
            .to_owned()
    })
}

/// `cmux customize library expire`: every layer past its bound off, by age
/// first, so a network that hangs keeps none on; then the PRs still on asked
/// about on GitHub (one that does not answer in time stays judged by age).
/// The app runs it at launch.
pub(super) fn run(customize: &Customize, origin: &str, now_ms: u64) -> Result<Answer, Failure> {
    let app = super::pr::App::find();
    let mut expiry =
        cmux_customize::library::expire::Expiry { now_ms, app_abi: app.abi, ..Default::default() };
    let mut expiring = customize.expire_stale(&expiry, origin);
    let on_prs: Vec<(String, u64)> = customize
        .library()
        .map(|listing| {
            listing
                .entries
                .iter()
                .filter(|entry| entry.on)
                .filter_map(|entry| entry.code.as_ref())
                .filter(|code| code.kind == CodeKind::Pr)
                .map(|code| (code.repo.clone(), code.pr))
                .collect()
        })
        .unwrap_or_default();
    if !on_prs.is_empty()
        && let Ok(http) = super::pr::Http::with_timeout(ASK_ONE)
    {
        let started = Instant::now();
        for (repo, pr) in on_prs {
            if started.elapsed() > ASK_ALL {
                break;
            }
            if let Some(word) = ended(&http, &repo, pr) {
                expiry.ended.insert((repo, pr), word);
            }
        }
    }
    if !expiry.ended.is_empty() {
        let more = customize.expire_stale(&expiry, origin);
        expiring.expired.extend(more.expired);
        expiring.problems.extend(more.problems);
    }
    let mut human = if expiring.expired.is_empty() {
        "nothing past its bound\n".to_owned()
    } else {
        String::new()
    };
    human.push_str(&super::library::expired_lines(&expiring.expired, Some(&expiring)));
    Ok(Answer::Library { json: json!(expiring), human })
}
