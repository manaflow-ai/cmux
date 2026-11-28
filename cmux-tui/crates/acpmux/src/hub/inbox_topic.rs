//! Group work by its subject while keeping each sender's identity on its original post.
use super::*;

pub(in crate::hub) fn topic(
    explicit: Option<&str>,
    text: &str,
    notice: Option<&Value>,
    sender: &str,
) -> String {
    if let Some(key) = explicit {
        return key.to_owned();
    }
    let title = notice.and_then(|n| n["title"].as_str()).unwrap_or("");
    let first = relay_body(text).lines().next().unwrap_or("");
    for line in [title, first] {
        if let Some((_, rest)) = line.split_once(" on runner label ")
            && let Some((label, _)) = rest.split_once(" queued with no runner")
            && !label.is_empty()
            && label.len() <= 200
            && !label.chars().any(char::is_control)
        {
            return format!("topic:ops/runner-capacity/{label}");
        }
        if let Some((slug, _)) = line.strip_prefix("GOAL ").and_then(|s| s.split_once(':'))
            && component(slug)
        {
            return format!("topic:goal/{slug}");
        }
    }

    // A tool often puts the qualified PR URL in its structured links and only "#N" in its title.
    let links = notice
        .and_then(|n| n["links"].as_array())
        .into_iter()
        .flatten()
        .filter_map(|link| link["url"].as_str());
    if let Some(key) =
        links.chain(title.split_whitespace()).chain(first.split_whitespace()).find_map(pull_topic)
    {
        return key;
    }
    if let Some(n) = first_pr(title).or_else(|| first_pr(first)) {
        return format!("pr:{n}");
    }
    if let Some(host) = notice.and_then(|n| n["host"].as_str()).filter(|s| component(s)) {
        return format!("topic:host/{host}");
    }
    thread_key(None, sender, text)
}

fn component(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 200
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}

fn pull_topic(word: &str) -> Option<String> {
    let word = word.trim_matches(|c: char| "[]()<>.,:".contains(c));
    let (repo, number) = if let Some(path) = word.strip_prefix("https://github.com/") {
        let (repo, tail) = path.split_once("/pull/")?;
        (repo, tail.split(['/', '?', '#']).next()?)
    } else {
        word.split_once('#')?
    };
    let parts: Vec<_> = repo.split('/').collect();
    if parts.len() > 2 || !parts.into_iter().all(component) {
        return None;
    }
    let number = number.parse::<u64>().ok().filter(|n| *n > 0)?;
    Some(format!("topic:pr/{}/{number}", repo.to_ascii_lowercase()))
}

#[cfg(test)]
#[path = "inbox_topic_tests.rs"]
mod tests;
