//! What a Feed GitHub item's action does (`FeedGitHubActions.perform`): the app reads the item
//! from the daemon, sends its facts, and runs the plan (opens the link, starts an agent with the
//! draft, or types the command into a new terminal).

use serde::{Deserialize, Serialize};

/// The item's GitHub facts, as the daemon reports them.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    /// The actions the daemon offers for this item (`github_actions`); nil offers none.
    #[serde(default)]
    pub github_actions: Option<Vec<String>>,
    /// The item's own title, the fallback for the agent draft.
    #[serde(default)]
    pub title: Option<String>,
    /// The item's GitHub detail; nil plans nothing.
    #[serde(default)]
    pub github: Option<Detail>,
}

/// `FeedDaemonItem.github`.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
pub struct Detail {
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub number: Option<i64>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub repo: Option<String>,
}

/// What the app does for the action.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Plan {
    /// Nothing (not offered, no link, missing facts, or an action not built yet).
    None,
    /// Open the item's link in the browser.
    Open { url: String },
    /// Open an agent tab in the focused pane with this draft.
    StartAgent { draft: String },
    /// Open a terminal tab in the focused pane typing this (newline included).
    Terminal { typing: String },
}

/// The plan for `action` on `item`. `url_valid` is whether the app could parse the link as a URL
/// (`URL(string:)`); `worktrees_root` is `BuildStatePaths.current.githubWorktrees.path`.
pub fn plan(
    action: &str,
    item: &Item,
    url_valid: bool,
    comment: Option<&str>,
    worktrees_root: &str,
) -> Plan {
    // Only an action the daemon offers for this item, never one the caller names.
    if !item.github_actions.as_ref().is_some_and(|actions| actions.iter().any(|a| a == action)) {
        return Plan::None;
    }
    let Some(detail) = &item.github else { return Plan::None };
    let Some(url) = detail.url.clone() else { return Plan::None };
    if !url_valid {
        return Plan::None;
    }
    match action {
        "open" => Plan::Open { url },
        "start_agent" => {
            let title = detail.title.as_deref().or(item.title.as_deref()).unwrap_or("");
            Plan::StartAgent {
                draft: format!("Review this GitHub pull request:\n{url}\n\nTitle: {title}"),
            }
        }
        "checkout" => {
            let (Some(number), Some(branch), Some(repo)) =
                (detail.number, &detail.branch, &detail.repo)
            else {
                return Plan::None;
            };
            let root = worktrees_root;
            let slug = format!("{}-pr-{number}", repo.replace('/', "-"));
            let path = format!("{root}/{slug}");
            let (qr, qp, qb) = (quote(root), quote(&path), quote(branch));
            let command = format!(
                "mkdir -p {qr} && if [ ! -d {qp} ]; then gh repo clone {} {qp}; fi; git -C {qp} fetch origin pull/{number}/head:{qb}; git -C {qp} checkout {qb}",
                quote(repo)
            );
            Plan::Terminal { typing: command + "\n" }
        }
        "approve" => Plan::Terminal { typing: format!("gh pr review {} --approve\n", quote(&url)) },
        "comment" => {
            let Some(text) = comment else { return Plan::None };
            if text.trim().is_empty() {
                return Plan::None;
            }
            Plan::Terminal {
                typing: format!("gh pr comment {} --body {}\n", quote(&url), quote(text)),
            }
        }
        // Request changes waits for a comment editor that collects a review body.
        _ => Plan::None,
    }
}

/// One shell word: single quotes, an inner quote closed, escaped and reopened.
pub fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(actions: &[&str]) -> Item {
        Item {
            github_actions: Some(actions.iter().map(|a| (*a).to_owned()).collect()),
            title: Some("Item title".into()),
            github: Some(Detail {
                url: Some("https://github.com/o/r/pull/7".into()),
                title: Some("Fix it".into()),
                number: Some(7),
                branch: Some("fix'it".into()),
                repo: Some("o/r".into()),
            }),
        }
    }

    const ALL: &[&str] =
        &["open", "start_agent", "checkout", "approve", "comment", "request_changes"];

    #[test]
    fn only_offered_actions_plan() {
        assert_eq!(plan("open", &item(&["approve"]), true, None, "/w"), Plan::None);
        let mut none = item(ALL);
        none.github_actions = None;
        assert_eq!(plan("open", &none, true, None, "/w"), Plan::None);
        assert_eq!(
            plan("open", &item(ALL), true, None, "/w"),
            Plan::Open { url: "https://github.com/o/r/pull/7".into() }
        );
    }

    #[test]
    fn needs_a_detail_and_a_valid_link() {
        let mut it = item(ALL);
        assert_eq!(plan("open", &it, false, None, "/w"), Plan::None);
        it.github.as_mut().unwrap().url = None;
        assert_eq!(plan("open", &it, true, None, "/w"), Plan::None);
        it.github = None;
        assert_eq!(plan("open", &it, true, None, "/w"), Plan::None);
    }

    #[test]
    fn agent_draft_falls_back_to_the_item_title() {
        let mut it = item(ALL);
        assert_eq!(
            plan("start_agent", &it, true, None, "/w"),
            Plan::StartAgent { draft: "Review this GitHub pull request:\nhttps://github.com/o/r/pull/7\n\nTitle: Fix it".into() }
        );
        it.github.as_mut().unwrap().title = None;
        assert_eq!(
            plan("start_agent", &it, true, None, "/w"),
            Plan::StartAgent { draft: "Review this GitHub pull request:\nhttps://github.com/o/r/pull/7\n\nTitle: Item title".into() }
        );
        it.title = None;
        assert_eq!(
            plan("start_agent", &it, true, None, "/w"),
            Plan::StartAgent {
                draft: "Review this GitHub pull request:\nhttps://github.com/o/r/pull/7\n\nTitle: "
                    .into()
            }
        );
    }

    #[test]
    fn checkout_quotes_every_word() {
        assert_eq!(
            plan("checkout", &item(ALL), true, None, "/w t"),
            Plan::Terminal {
                typing: "mkdir -p '/w t' && if [ ! -d '/w t/o-r-pr-7' ]; then gh repo clone 'o/r' '/w t/o-r-pr-7'; fi; git -C '/w t/o-r-pr-7' fetch origin pull/7/head:'fix'\\''it'; git -C '/w t/o-r-pr-7' checkout 'fix'\\''it'\n".into()
            }
        );
        for missing in 0..3 {
            let mut it = item(ALL);
            let detail = it.github.as_mut().unwrap();
            match missing {
                0 => detail.number = None,
                1 => detail.branch = None,
                _ => detail.repo = None,
            }
            assert_eq!(plan("checkout", &it, true, None, "/w"), Plan::None);
        }
    }

    #[test]
    fn approve_and_comment_commands() {
        assert_eq!(
            plan("approve", &item(ALL), true, None, "/w"),
            Plan::Terminal {
                typing: "gh pr review 'https://github.com/o/r/pull/7' --approve\n".into()
            }
        );
        assert_eq!(
            plan("comment", &item(ALL), true, Some("it's ok"), "/w"),
            Plan::Terminal {
                typing: "gh pr comment 'https://github.com/o/r/pull/7' --body 'it'\\''s ok'\n"
                    .into()
            }
        );
        assert_eq!(plan("comment", &item(ALL), true, Some(" \n\t"), "/w"), Plan::None);
        assert_eq!(plan("comment", &item(ALL), true, None, "/w"), Plan::None);
        assert_eq!(plan("request_changes", &item(ALL), true, Some("x"), "/w"), Plan::None);
    }
}
