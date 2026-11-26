//! `newTab.submit`: the new tab field's decision for the paths without a page
//! (CLI `cmux tab new-from-text`, its MCP tool, the palette), from the field's
//! intent (`NewTabIntent`), so a typed `!ls`, `github.com` or prompt opens the
//! same tab from any surface. The app classifies the text, resolves the
//! omnibar's typo fix and the search URL, and opens what the plan names.

use serde::{Deserialize, Serialize};

/// The field's intent (`NewTabIntent`'s JSON: `kind` and its value).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Intent {
    None,
    Terminal { command: String },
    Url { url: String },
    Prompt { text: String },
    Refused { reason: String },
}

/// What a submission opens.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "plan", rename_all = "camelCase")]
pub enum Plan {
    /// Nothing typed: the new tab page itself.
    Page,
    /// `!` first: a terminal with the command typed, never run.
    Terminal {
        command: String,
    },
    Browser {
        url: String,
    },
    /// A prompt: an agent chat that sends it, on `harness` when given.
    Chat {
        prompt: String,
        harness: Option<String>,
    },
    /// Nothing opens; the person reads Mac Screen's pairing link refusal.
    Refused,
}

/// The facts a plan needs, the app's lookups done.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Submission {
    /// `None` reads as nothing typed.
    #[serde(default)]
    pub intent: Option<Intent>,
    /// The explicit web-search choice: it searches any text but a `!` command.
    #[serde(default)]
    pub search: bool,
    #[serde(default)]
    pub agent: Option<String>,
    /// The person typed the text (the palette): a top-level-domain typo is
    /// fixed as the omnibar fixes it; never for CLI, MCP or scripts.
    #[serde(default)]
    pub fixes_host_typos: bool,
    /// The omnibar's typo fix for the text (`OmniboxResolver.commitTypoFix`).
    #[serde(default)]
    pub typo_fix: Option<String>,
    /// Whether the intent's address parses as a URL.
    #[serde(default = "yes")]
    pub url_valid: bool,
    /// The search engine's URL for the trimmed text.
    #[serde(default)]
    pub search_url: Option<String>,
}

fn yes() -> bool {
    true
}

impl Default for Submission {
    /// Nothing typed; an address parses (as the wire's default).
    fn default() -> Self {
        Self {
            intent: None,
            search: false,
            agent: None,
            fixes_host_typos: false,
            typo_fix: None,
            url_valid: true,
            search_url: None,
        }
    }
}

impl Submission {
    /// Whether the app needs the omnibar's typo fix to plan (it is looked up
    /// only then).
    pub fn wants_typo_fix(intent: &Intent, search: bool, fixes_host_typos: bool) -> bool {
        fixes_host_typos && !search && matches!(intent, Intent::Url { .. } | Intent::Prompt { .. })
    }

    /// Whether the app needs the search URL to plan.
    pub fn wants_search_url(intent: &Intent, search: bool) -> bool {
        search && matches!(intent, Intent::Url { .. } | Intent::Prompt { .. })
    }
}

/// The plan for a submission.
pub fn plan(submission: &Submission) -> Plan {
    let intent = submission.intent.clone().unwrap_or(Intent::None);
    if Submission::wants_typo_fix(&intent, submission.search, submission.fixes_host_typos)
        && let Some(fixed) = &submission.typo_fix
    {
        return Plan::Browser { url: fixed.clone() };
    }
    let searched = || submission.search_url.clone().map_or(Plan::Page, |url| Plan::Browser { url });
    match intent {
        Intent::None => Plan::Page,
        Intent::Refused { .. } => Plan::Refused,
        Intent::Terminal { command } => Plan::Terminal { command },
        Intent::Url { url } if !submission.search => {
            if submission.url_valid {
                Plan::Browser { url }
            } else {
                Plan::Page
            }
        }
        Intent::Prompt { text } if !submission.search => Plan::Chat {
            prompt: text,
            harness: submission.agent.clone().filter(|agent| !agent.is_empty()),
        },
        Intent::Url { .. } | Intent::Prompt { .. } => searched(),
    }
}

/// A native New Tab page pick's kind (`AgentPaneTabKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabKind {
    Agent,
    Terminal,
    Browser,
}

/// The tab a native pick opens (`AgentPaneOpenTab`, less its folder).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenTab {
    pub kind: TabKind,
    pub text: String,
    pub search: bool,
    pub run: bool,
}

/// Whether a native pick of `kind` with `text` plans first (a Browser pick
/// with text keeps the submission table's commands, searches and typo fixes).
pub fn native_plans(kind: TabKind, text: &str) -> bool {
    kind == TabKind::Browser && !text.trim().is_empty()
}

/// The tab a native pick opens: the text trimmed, an explicit Terminal pick
/// runs; a planned Browser pick follows its plan (`None`: refused).
pub fn native_request(
    kind: TabKind,
    text: &str,
    search: bool,
    plan: Option<&Plan>,
) -> Option<OpenTab> {
    let trimmed = text.trim();
    let mut request =
        OpenTab { kind, text: trimmed.to_owned(), search, run: kind == TabKind::Terminal };
    if !native_plans(kind, trimmed) {
        return Some(request);
    }
    match plan {
        Some(Plan::Terminal { command }) => {
            request.kind = TabKind::Terminal;
            request.text = command.clone();
        }
        Some(Plan::Chat { .. }) => request.search = true,
        Some(Plan::Browser { url }) => {
            request.text = url.clone();
            request.search = false;
        }
        Some(Plan::Refused) => return None,
        Some(Plan::Page) | None => {}
    }
    Some(request)
}

/// Whether what a plan opens is a tool that goes beside the chat, never into
/// the chat dock (a terminal or a browser), for a person's submission; a
/// script's (CLI `tab new-from-text`, MCP) opens in the pane it named.
pub fn opens_beside_chat(plan: &Plan, by_person: bool) -> bool {
    by_person && matches!(plan, Plan::Terminal { .. } | Plan::Browser { .. })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(url: &str) -> Option<Intent> {
        Some(Intent::Url { url: url.into() })
    }
    fn prompt(text: &str) -> Option<Intent> {
        Some(Intent::Prompt { text: text.into() })
    }

    #[test]
    fn nothing_typed_is_the_page() {
        assert_eq!(plan(&Submission::default()), Plan::Page);
        assert_eq!(
            plan(&Submission { intent: Some(Intent::None), search: true, ..Submission::default() }),
            Plan::Page
        );
    }

    #[test]
    fn a_pairing_link_refuses() {
        let refused = Some(Intent::Refused { reason: "pair".into() });
        assert_eq!(
            plan(&Submission { intent: refused.clone(), ..Submission::default() }),
            Plan::Refused
        );
        // The typo fix never applies to a refusal.
        let fixed = Submission {
            intent: refused,
            fixes_host_typos: true,
            typo_fix: Some("x".into()),
            ..Submission::default()
        };
        assert_eq!(plan(&fixed), Plan::Refused);
    }

    #[test]
    fn a_command_opens_a_terminal_even_when_searching() {
        let intent = Some(Intent::Terminal { command: "ls".into() });
        let submission = Submission {
            intent,
            search: true,
            fixes_host_typos: true,
            typo_fix: Some("https://x.com".into()),
            ..Submission::default()
        };
        assert_eq!(plan(&submission), Plan::Terminal { command: "ls".into() });
    }

    #[test]
    fn an_address_opens_a_browser() {
        assert_eq!(
            plan(&Submission { intent: url("https://github.com/"), ..Submission::default() }),
            Plan::Browser { url: "https://github.com/".into() }
        );
        assert_eq!(
            plan(&Submission { intent: url("::"), url_valid: false, ..Submission::default() }),
            Plan::Page
        );
    }

    #[test]
    fn a_prompt_opens_a_chat_on_its_harness() {
        assert_eq!(
            plan(&Submission {
                intent: prompt("fix it"),
                agent: Some("codex".into()),
                ..Submission::default()
            }),
            Plan::Chat { prompt: "fix it".into(), harness: Some("codex".into()) }
        );
        assert_eq!(
            plan(&Submission {
                intent: prompt("fix it"),
                agent: Some(String::new()),
                ..Submission::default()
            }),
            Plan::Chat { prompt: "fix it".into(), harness: None }
        );
        assert_eq!(
            plan(&Submission { intent: prompt("fix it"), ..Submission::default() }),
            Plan::Chat { prompt: "fix it".into(), harness: None }
        );
    }

    // SearchEngineEveryPathTests: search sends an address or a prompt to the engine.
    #[test]
    fn search_uses_the_engine() {
        for intent in [url("github.com"), prompt("weather")] {
            let submission = Submission {
                intent,
                search: true,
                search_url: Some("https://duck.com/?q=x".into()),
                ..Submission::default()
            };
            assert_eq!(plan(&submission), Plan::Browser { url: "https://duck.com/?q=x".into() });
        }
        assert_eq!(
            plan(&Submission { intent: prompt("weather"), search: true, ..Submission::default() }),
            Plan::Page
        );
    }

    #[test]
    fn a_typed_typo_is_fixed_only_for_a_person_not_searching() {
        let fixed = Submission {
            intent: prompt("github.cmo"),
            fixes_host_typos: true,
            typo_fix: Some("https://github.com/".into()),
            ..Submission::default()
        };
        assert_eq!(plan(&fixed), Plan::Browser { url: "https://github.com/".into() });
        let url_typo = Submission { intent: url("github.cmo"), ..fixed.clone() };
        assert_eq!(plan(&url_typo), Plan::Browser { url: "https://github.com/".into() });
        let scripted = Submission { fixes_host_typos: false, ..fixed.clone() };
        assert_eq!(plan(&scripted), Plan::Chat { prompt: "github.cmo".into(), harness: None });
        let searching =
            Submission { search: true, search_url: Some("https://s/?q".into()), ..fixed.clone() };
        assert_eq!(plan(&searching), Plan::Browser { url: "https://s/?q".into() });
        let no_fix = Submission { typo_fix: None, ..fixed };
        assert_eq!(plan(&no_fix), Plan::Chat { prompt: "github.cmo".into(), harness: None });
    }

    #[test]
    fn lookups_are_wanted_only_when_used() {
        let u = Intent::Url { url: "a".into() };
        let t = Intent::Terminal { command: "ls".into() };
        assert!(Submission::wants_typo_fix(&u, false, true));
        assert!(!Submission::wants_typo_fix(&u, true, true));
        assert!(!Submission::wants_typo_fix(&u, false, false));
        assert!(!Submission::wants_typo_fix(&t, false, true));
        assert!(Submission::wants_search_url(&u, true));
        assert!(!Submission::wants_search_url(&u, false));
        assert!(!Submission::wants_search_url(&Intent::None, true));
    }

    // NewTabPagePickInPlaceTests: a native Browser pick keeps the table's commands, searches and fixes.
    #[test]
    fn native_browser_picks_follow_the_plan() {
        let terminal = Plan::Terminal { command: "ls".into() };
        assert_eq!(
            native_request(TabKind::Browser, " !ls ", false, Some(&terminal)),
            Some(OpenTab { kind: TabKind::Terminal, text: "ls".into(), search: false, run: false })
        );
        let chat = Plan::Chat { prompt: "weather".into(), harness: None };
        assert_eq!(
            native_request(TabKind::Browser, "weather", false, Some(&chat)),
            Some(OpenTab {
                kind: TabKind::Browser,
                text: "weather".into(),
                search: true,
                run: false
            })
        );
        let browser = Plan::Browser { url: "https://github.com/".into() };
        assert_eq!(
            native_request(TabKind::Browser, "github.cmo", true, Some(&browser)),
            Some(OpenTab {
                kind: TabKind::Browser,
                text: "https://github.com/".into(),
                search: false,
                run: false
            })
        );
        assert_eq!(native_request(TabKind::Browser, "pair", false, Some(&Plan::Refused)), None);
        assert_eq!(
            native_request(TabKind::Browser, "x", true, Some(&Plan::Page)),
            Some(OpenTab { kind: TabKind::Browser, text: "x".into(), search: true, run: false })
        );
    }

    #[test]
    fn other_native_picks_keep_their_kind() {
        assert_eq!(
            native_request(TabKind::Terminal, " make ", false, Some(&Plan::Refused)),
            Some(OpenTab {
                kind: TabKind::Terminal,
                text: "make".into(),
                search: false,
                run: true
            })
        );
        assert_eq!(
            native_request(TabKind::Agent, "hi", true, None),
            Some(OpenTab { kind: TabKind::Agent, text: "hi".into(), search: true, run: false })
        );
        assert_eq!(
            native_request(TabKind::Browser, "   ", false, Some(&Plan::Refused)),
            Some(OpenTab {
                kind: TabKind::Browser,
                text: String::new(),
                search: false,
                run: false
            })
        );
        assert!(!native_plans(TabKind::Browser, "  "));
        assert!(native_plans(TabKind::Browser, "a"));
        assert!(!native_plans(TabKind::Terminal, "a"));
    }

    // ChatLinkReusesRightPaneTests / MacScreenTests: only a person's tools open beside the chat.
    #[test]
    fn tools_open_beside_the_chat_for_a_person() {
        let tools = [Plan::Terminal { command: String::new() }, Plan::Browser { url: "u".into() }];
        for plan in &tools {
            assert!(opens_beside_chat(plan, true));
            assert!(!opens_beside_chat(plan, false));
        }
        for plan in [Plan::Page, Plan::Refused, Plan::Chat { prompt: "p".into(), harness: None }] {
            assert!(!opens_beside_chat(&plan, true));
        }
    }

    #[test]
    fn intents_decode_from_new_tab_intent_json() {
        let decoded: Vec<Intent> = serde_json::from_str(
            r#"[{"kind":"none"},{"kind":"terminal","command":"ls"},{"kind":"url","url":"a.com"},
                {"kind":"prompt","text":"hi"},{"kind":"refused","reason":"r"}]"#,
        )
        .unwrap();
        assert_eq!(
            decoded,
            vec![
                Intent::None,
                Intent::Terminal { command: "ls".into() },
                Intent::Url { url: "a.com".into() },
                Intent::Prompt { text: "hi".into() },
                Intent::Refused { reason: "r".into() },
            ]
        );
    }
}
