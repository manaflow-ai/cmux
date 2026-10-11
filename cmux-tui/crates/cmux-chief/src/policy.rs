//! The Chief's approval policy and harness routing, as decisions every brain
//! makes the same way (the shared behavior corpus, `policy` cases; the
//! TypeScript `policy.ts`). Each brain applies them its own way:
//! optchat-chief per turn session and per spawned child.

use serde_json::Value;

/// The key of the per-Chief setting.
pub const REMOTE_AUTO_APPROVE: &str = "remote.autoApprove";
/// The policy that asks a person for every local effect.
pub const ASK: &str = "ask";

/// `remote.autoApprove` from a Chief's settings (`{"remote": {"autoApprove":
/// bool}}`): a remote-origin turn (the owner's own paired device) runs with
/// the configured policy instead of `ask`. Default true (Lawrence,
/// 2026-10-06: "i dont want stuff to require my approval"); a missing,
/// unreadable or non-bool value is the default.
pub fn remote_auto_approve(settings: &Value) -> bool {
    settings.pointer("/remote/autoApprove").and_then(Value::as_bool).unwrap_or(true)
}

/// The policy a turn runs with: `ask` when a paired device's message drives
/// it (or a remote turn it supersedes) and remote.autoApprove is off; else
/// the configured one.
pub fn turn_policy(remote: bool, auto_approve: bool, configured: &str) -> String {
    if remote && !auto_approve { ASK.to_owned() } else { configured.to_owned() }
}

/// The policy floor for a child spawned now: `ask` during an ask turn or
/// while an `ask` child or subagent is live, unless remote.autoApprove is on;
/// None leaves the child its own policy.
pub fn spawn_floor(
    auto_approve: bool,
    turn_ask: bool,
    ask_child_live: bool,
    ask_subagent_live: bool,
) -> Option<&'static str> {
    if auto_approve {
        return None;
    }
    (turn_ask || ask_child_live || ask_subagent_live).then_some(ASK)
}

/// Which acpmux harness may answer for the Chief (Lawrence, 2026-10-05: only
/// acpmux's own Claude Code adapter). A Claude harness is admitted only when
/// acpmux reports it as kind `claude-stdio`; an external ACP adapter is
/// refused whatever its profile is named. `claude-sr` and `claude` are
/// routes, not profile names: `claude-sr` asks for a `claude-stdio` profile
/// whose command is `sr claude proxy` (or `claude` with the team subrouter as
/// its base URL), `claude` for one whose command is `claude`. Any other name
/// is a profile: a Claude-family one must still be `claude-stdio`.
pub mod harness {
    use serde_json::Value;

    /// acpmux's kind for its own Claude Code adapter.
    pub const CLAUDE_STDIO: &str = "claude-stdio";

    /// The team subrouter's addresses (a `claude` profile with one of them as
    /// `ANTHROPIC_BASE_URL` is the subrouter route too).
    pub const TEAM_SUBROUTER_URLS: [&str; 3] = [
        "http://cmux-lawrences-mac-mini:31415",
        "http://cmux-lawrences-mac-mini.tail137216.ts.net:31415",
        "http://100.89.225.106:31415",
    ];

    /// An admitted harness: the profile a session asks for and what acpmux
    /// says it runs.
    #[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
    pub struct Admission {
        pub profile: String,
        pub kind: String,
        /// The first word of its command.
        pub argv0: String,
        /// `claude`, `codex` or `other`.
        pub family: String,
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Route {
        Subrouter,
        Direct,
    }

    impl Route {
        fn of(name: &str) -> Option<Route> {
            match name {
                "claude-sr" => Some(Route::Subrouter),
                "claude" => Some(Route::Direct),
                _ => None,
            }
        }

        fn command(self) -> &'static str {
            match self {
                Route::Subrouter => "`sr claude proxy`",
                Route::Direct => "`claude`",
            }
        }

        fn matches(self, argv: &[String]) -> bool {
            let Some(first) = argv.first() else { return false };
            let exe = basename(first);
            match self {
                Route::Subrouter => {
                    matches!(exe.as_str(), "sr" | "subrouter")
                        && argv.get(1..).is_some_and(|rest| rest == ["claude", "proxy"])
                }
                Route::Direct => exe == "claude",
            }
        }
    }

    /// Whether `requested` is a reserved route name (`claude-sr`, `claude`).
    pub fn is_route(requested: &str) -> bool {
        Route::of(requested).is_some()
    }

    fn routed_to_team_subrouter(p: &Value) -> bool {
        let argv = argv_of(p);
        let url = p
            .get("env")
            .and_then(|e| e.get("ANTHROPIC_BASE_URL"))
            .and_then(Value::as_str)
            .map(|u| u.trim().trim_end_matches('/'));
        argv.len() == 1
            && basename(&argv[0]) == "claude"
            && url.is_some_and(|u| TEAM_SUBROUTER_URLS.contains(&u))
    }

    /// The last path component (`/a/b/sr` -> `sr`), as JavaScript splits on `/`.
    fn basename(word: &str) -> String {
        word.rsplit('/').next().unwrap_or_default().to_owned()
    }

    fn kind_of(profile: &Value) -> String {
        profile.get("kind").and_then(Value::as_str).unwrap_or("acp").to_owned()
    }

    fn argv_of(profile: &Value) -> Vec<String> {
        profile
            .get("argv")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    }

    fn profiles(answer: &Value) -> Vec<(&String, &Value)> {
        answer.get("harnesses").and_then(Value::as_object).into_iter().flatten().collect()
    }

    fn what_is(answer: &Value, name: &str) -> String {
        match answer.get("harnesses").and_then(|h| h.get(name)) {
            Some(p) => {
                let argv = argv_of(p);
                let mut text = format!(
                    "acpmux's {name} is kind {} ({})",
                    kind_of(p),
                    argv.first().map_or("no command", String::as_str)
                );
                if let Some(why) = p.get("description").and_then(Value::as_str) {
                    text.push_str(&format!(", \"{why}\""));
                }
                text
            }
            None => format!("acpmux has no harness named {name}"),
        }
    }

    /// The family of `harness` in an `_acpmux/harnesses` answer: the one
    /// acpmux reports, else derived from its kind and its command's words
    /// (acpmux's order: codex before claude), never from its name.
    pub fn family(answer: &Value, harness: &str) -> Result<String, String> {
        let Some(profile) = answer.get("harnesses").and_then(|h| h.get(harness)) else {
            return Err(format!("acpmux has no harness named {harness}"));
        };
        if let Some(family) = profile.get("family").and_then(Value::as_str) {
            return Ok(match family {
                "claude" | "codex" => family.to_owned(),
                _ => "other".to_owned(),
            });
        }
        if profile.get("kind").and_then(Value::as_str) == Some(CLAUDE_STDIO) {
            return Ok("claude".into());
        }
        let words: Vec<String> =
            argv_of(profile).iter().map(|w| basename(w).to_lowercase()).collect();
        for needle in ["codex", "claude"] {
            if words.iter().any(|w| w.contains(needle)) {
                return Ok(needle.to_owned());
            }
        }
        Ok("other".into())
    }

    /// Admits `requested` (a route or a profile name) against an
    /// `_acpmux/harnesses` answer, or says why not.
    pub fn admit(answer: &Value, requested: &str) -> Result<Admission, String> {
        let Some(route) = Route::of(requested) else {
            return admit_profile(answer, requested);
        };
        let routed = |p: &Value| route == Route::Subrouter && routed_to_team_subrouter(p);
        let mut found: Vec<(&String, &Value)> = profiles(answer)
            .into_iter()
            .filter(|(_, p)| {
                kind_of(p) == CLAUDE_STDIO
                    && p.get("unavailable").is_none()
                    && (route.matches(&argv_of(p)) || routed(p))
            })
            .collect();
        // A real `sr claude proxy` first, then the reserved name's profile.
        found.sort_by_key(|(name, p)| (routed(p), name.as_str() != requested, name.to_string()));
        let Some((name, p)) = found.first() else {
            return Err(format!(
                "the Chief runs Claude only through acpmux's own Claude Code adapter (kind {CLAUDE_STDIO}), and {requested} asks for one running {}; acpmux has none: {}",
                route.command(),
                what_is(answer, requested)
            ));
        };
        Ok(Admission {
            profile: (*name).clone(),
            kind: CLAUDE_STDIO.to_owned(),
            argv0: argv_of(p).first().cloned().unwrap_or_default(),
            family: "claude".into(),
        })
    }

    /// A profile by its exact name: refused when it is Claude and not kind
    /// `claude-stdio`.
    pub fn admit_profile(answer: &Value, profile: &str) -> Result<Admission, String> {
        let Some(p) = answer.get("harnesses").and_then(|h| h.get(profile)) else {
            return Err(format!("acpmux has no harness named {profile}"));
        };
        let family = family(answer, profile)?;
        let kind = kind_of(p);
        if family == "claude" && kind != CLAUDE_STDIO {
            return Err(format!(
                "the Chief runs Claude only through acpmux's own Claude Code adapter (kind {CLAUDE_STDIO}); {}",
                what_is(answer, profile)
            ));
        }
        Ok(Admission {
            profile: profile.to_owned(),
            kind,
            argv0: argv_of(p).first().cloned().unwrap_or_default(),
            family,
        })
    }
}
