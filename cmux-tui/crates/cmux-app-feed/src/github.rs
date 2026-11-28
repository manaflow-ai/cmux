//! A GitHub card's actions and where a Feed item opens (`FeedGitHubActions`): the app opens the
//! link, seeds the agent draft or types the command into a new terminal tab.

use crate::json::{arr_at, str_at};
use crate::text::single_quoted as quote;
use serde::Serialize;
use serde_json::Value;

/// What a card action does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum Plan {
    /// Nothing: the action is not the card's, or a field it needs is missing.
    None,
    OpenUrl {
        url: String,
    },
    /// Open an agent tab in the focused pane with this draft.
    Draft {
        draft: String,
    },
    /// Open a terminal tab in the focused pane and type this command (a newline follows).
    Type {
        command: String,
    },
}

/// The plan of `action` on `item`; `root` is where PR checkouts live, `text` a comment's body.
pub fn plan(action: &str, item: &Value, text: Option<&str>, root: &str) -> Plan {
    let offered = arr_at(item, "github_actions")
        .is_some_and(|actions| actions.iter().any(|entry| entry.as_str() == Some(action)));
    if !offered {
        return Plan::None;
    }
    let Some(detail) = item.get("github").filter(|detail| detail.is_object()) else {
        return Plan::None;
    };
    let Some(url) = str_at(detail, "url").filter(|url| !url.is_empty()) else { return Plan::None };
    match action {
        "open" => Plan::OpenUrl { url: url.to_owned() },
        "start_agent" => {
            let title =
                str_at(detail, "title").or_else(|| str_at(item, "title")).unwrap_or_default();
            Plan::Draft {
                draft: format!("Review this GitHub pull request:\n{url}\n\nTitle: {title}"),
            }
        }
        "checkout" => {
            let number = detail.get("number").and_then(Value::as_i64);
            let (Some(number), Some(branch), Some(repository)) =
                (number, str_at(detail, "branch"), str_at(detail, "repo"))
            else {
                return Plan::None;
            };
            let slug = format!("{}-pr-{number}", repository.replace('/', "-"));
            let path = format!("{root}/{slug}");
            Plan::Type {
                command: format!(
                    "mkdir -p {} && if [ ! -d {} ]; then gh repo clone {} {}; fi; git -C {} fetch origin pull/{number}/head:{}; git -C {} checkout {}",
                    quote(root),
                    quote(&path),
                    quote(repository),
                    quote(&path),
                    quote(&path),
                    quote(branch),
                    quote(&path),
                    quote(branch),
                ),
            }
        }
        "approve" => Plan::Type { command: format!("gh pr review {} --approve", quote(url)) },
        "comment" => match text.filter(|text| !text.trim().is_empty()) {
            Some(text) => Plan::Type {
                command: format!("gh pr comment {} --body {}", quote(url), quote(text)),
            },
            None => Plan::None,
        },
        _ => Plan::None,
    }
}

/// Where an item opens.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "open", rename_all = "snake_case")]
pub enum OpenTarget {
    Url {
        url: String,
    },
    /// Reveal the tab the store finds by these.
    Tab {
        reported: Option<String>,
        terminal: Option<String>,
        agent_session: Option<String>,
    },
}

/// Where `item` opens: its link (`context.url`, else `github.url`; when that one is empty,
/// `prompt.url`), else its tab.
pub fn open_target(item: &Value) -> OpenTarget {
    let context = item.get("context").filter(|context| context.is_object());
    let prompt = item.get("prompt").filter(|prompt| prompt.is_object());
    let at = |key: &str| context.and_then(|context| str_at(context, key));
    let url = at("url")
        .or_else(|| item.get("github").and_then(|github| str_at(github, "url")))
        .filter(|url| !url.is_empty())
        .or_else(|| prompt.and_then(|prompt| str_at(prompt, "url")).filter(|url| !url.is_empty()));
    if let Some(url) = url {
        return OpenTarget::Url { url: url.to_owned() };
    }
    OpenTarget::Tab {
        reported: prompt
            .and_then(|prompt| str_at(prompt, "browser_tab"))
            .or_else(|| at("browser_tab"))
            .or_else(|| at("tab"))
            .map(str::to_owned),
        terminal: at("terminal").map(str::to_owned),
        agent_session: at("acp_session").map(str::to_owned),
    }
}
