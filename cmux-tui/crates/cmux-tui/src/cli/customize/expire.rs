//! `cmux customize library expire`: every experiment layer past its bound
//! off, with GitHub asked which PRs that are on merged or closed. The model
//! is `cmux_customize::library::expire`.

use cmux_customize::Customize;
use cmux_customize::library::CodeKind;
use serde_json::{Value, json};

use super::Failure;
use super::render::Answer;

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

/// `cmux customize library expire`: every layer past its bound off, the
/// PRs that are on asked about on GitHub first (one that does not answer
/// is judged by age alone). The app runs it at launch.
pub(super) fn run(customize: &Customize, origin: &str, now_ms: u64) -> Result<Answer, Failure> {
    let app = super::pr::App::find();
    let mut expiry =
        cmux_customize::library::expire::Expiry { now_ms, app_abi: app.abi, ..Default::default() };
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
        && let Ok(http) = super::pr::Http::new()
    {
        for (repo, pr) in on_prs {
            if let Some(word) = ended(&http, &repo, pr) {
                expiry.ended.insert(pr, word);
            }
        }
    }
    let expiring = customize.expire_stale(&expiry, origin);
    let mut human = if expiring.expired.is_empty() {
        "nothing past its bound\n".to_owned()
    } else {
        String::new()
    };
    human.push_str(&super::library::expired_lines(&expiring.expired, Some(&expiring)));
    Ok(Answer::Library { json: json!(expiring), human })
}
