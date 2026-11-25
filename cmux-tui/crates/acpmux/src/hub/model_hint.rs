//! Part of `Hub`; see `hub/mod.rs`. The "did you mean" hint for a `-m`
//! head that names a model, not a harness.

use super::*;

/// The model a `-m claude-…` name that is no model id is pointed at instead.
const CLAUDE_FALLBACK: &str = "claude-opus-5-5";

impl Hub {
    /// "did you mean codex/gpt-5.5": a `-m` head that is no harness may be a
    /// bare model id, or `HEAD/MODEL` may be a full id such as
    /// `opencode-go/deepseek-v4-flash`.
    pub(super) fn with_model_hint(
        &self,
        cfg: &crate::config::Config,
        head: &str,
        model: Option<&str>,
        err: String,
    ) -> String {
        let spec = match model {
            Some(m) => format!("{head}/{m}"),
            None => head.to_owned(),
        };
        let known = self.known_models.lock().unwrap();
        let mut hits: Vec<String> = Vec::new();
        let mut claude_harness: Option<&str> = None;
        for (name, p) in &cfg.harnesses {
            let mut ids: Vec<String> = p.models.iter().map(|m| m.id().to_owned()).collect();
            match p.kind {
                crate::config::HarnessKind::ClaudeStdio => {
                    if claude_harness.is_none() || name == "claude" {
                        claude_harness = Some(name);
                    }
                    ids.extend(crate::claude_stdio::models().iter().map(|(id, _)| id.to_string()))
                }
                crate::config::HarnessKind::Acp => {
                    ids.extend(known.get(name).into_iter().flatten().map(|(id, _)| id.clone()))
                }
                crate::config::HarnessKind::Terminal => {}
            }
            if ids.contains(&spec)
                || (p.kind == crate::config::HarnessKind::ClaudeStdio
                    && looks_like_claude_model_id(&spec))
            {
                hits.push(format!("{name}/{spec}"));
            }
        }
        hint_text(err, &spec, &hits, claude_harness)
    }
}

/// The error with its hint: the spelling to use when `spec` is a model id,
/// or, for a `claude…` name that is no model id (a harness profile such as
/// `claude-sr2` that this host lacks), never `claude/<name>`, which Claude
/// Code would refuse as an unrecognized model on every turn.
fn hint_text(err: String, spec: &str, hits: &[String], claude_harness: Option<&str>) -> String {
    if !hits.is_empty() {
        return format!("{err}. {spec:?} is a model id: write {}", hits.join(" or "));
    }
    if spec.starts_with("claude") {
        let mut hint = format!(
            "{err}. {spec:?} is a harness profile this host does not have: install it in config.json"
        );
        if let Some(h) = claude_harness {
            hint.push_str(&format!(", or use -m {h}/{CLAUDE_FALLBACK} -e medium"));
        }
        return hint;
    }
    match missing_harness_step(spec) {
        Some(step) => format!("{err}. {step}"),
        None => err,
    }
}

/// The next step for a harness name this host has no profile for, so a first
/// chat on an agent that is not set up never ends on a bare "unknown harness"
/// (cmuxterm-hq first-user journey, rule error-without-next-step): the Install
/// command for an agent cmux installs itself, the shipped example profile for
/// one it knows, the ACP Registry for another agent it knows by name. None for
/// any other name (a typo, a model name): the bare error stays.
fn missing_harness_step(spec: &str) -> Option<String> {
    let id = spec.split('/').next().unwrap_or(spec);
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return None;
    }
    if crate::harness_install::agent(id).is_ok() {
        return Some(format!(
            "{id:?} is not installed here: install it with `cmux harness install {id}`, \
             or the Install button in Settings > Agents"
        ));
    }
    if crate::cli::harness::example(id).is_some() {
        return Some(format!(
            "{id:?} is not set up here: install its CLI, then add it with \
             `cmux harness add {id} --example {id}`"
        ));
    }
    // An agent cmux knows by name (it has a mark) but ships no profile for: the ACP Registry adds it.
    if crate::chats::brand::exact(id).is_some() {
        return Some(format!(
            "{id:?} is not set up here: install its CLI, then `cmux harness registry` lists the agents \
             cmux can add with `cmux harness add ID --registry`"
        ));
    }
    None
}

/// Whether `spec` has the shape of a Claude model id: a family release
/// (`claude-opus-5-5`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`),
/// the older `claude-3-5-sonnet-…` shape, or an alias Claude Code takes
/// (`opus`, `sonnet[1m]`). A `[1m]` suffix is allowed. A harness profile
/// name such as `claude-sr2` or `claude-sr2-pipe` is none of these.
pub(super) fn looks_like_claude_model_id(spec: &str) -> bool {
    let base = spec.strip_suffix("[1m]").unwrap_or(spec);
    if matches!(base, "opus" | "sonnet" | "haiku" | "opusplan" | "default") {
        return true;
    }
    let Some(rest) = base.strip_prefix("claude-") else {
        return false;
    };
    if rest.starts_with(|c: char| c.is_ascii_digit()) {
        return true;
    }
    ["opus-", "sonnet-", "haiku-", "fable-"].iter().any(|family| {
        rest.strip_prefix(family).is_some_and(|v| v.starts_with(|c: char| c.is_ascii_digit()))
    })
}

#[cfg(test)]
mod tests {
    use super::{hint_text, looks_like_claude_model_id};

    #[test]
    fn claude_model_shapes() {
        for id in [
            "claude-opus-5-5",
            "claude-sonnet-4-6",
            "claude-haiku-4-5-20251001",
            "claude-opus-4-7[1m]",
            "claude-3-5-sonnet-20241022",
            "opus",
            "sonnet[1m]",
            "haiku",
        ] {
            assert!(looks_like_claude_model_id(id), "{id}");
        }
        for name in
            ["claude-sr2", "claude-sr2-pipe", "claude", "claude-opus", "claude-work", "claude-"]
        {
            assert!(!looks_like_claude_model_id(name), "{name}");
        }
    }

    #[test]
    fn harness_profile_gets_no_claude_model_suggestion() {
        let err = "unknown harness \"claude-sr2\"".to_owned();
        let out = hint_text(err, "claude-sr2", &[], Some("claude"));
        assert!(!out.contains("claude/claude-sr2"), "{out}");
        assert!(!out.contains("is a model id"), "{out}");
        assert!(out.contains("harness profile this host does not have"), "{out}");
        assert!(out.contains("-m claude/claude-opus-5-5 -e medium"), "{out}");
        assert!(!out.contains("fable"), "{out}");
    }

    #[test]
    fn a_missing_harness_names_its_next_step() {
        let codex = hint_text("unknown harness \"codex\"".into(), "codex", &[], None);
        assert!(codex.contains("`cmux harness install codex`"), "{codex}");
        let gemini = hint_text("unknown harness \"gemini\"".into(), "gemini", &[], None);
        assert!(gemini.contains("`cmux harness add gemini --example gemini`"), "{gemini}");
        for agent in ["grok", "cursor", "antigravity"] {
            let out =
                hint_text(format!("unknown harness {agent:?}"), &format!("{agent}/x"), &[], None);
            assert!(out.contains(&format!("{agent:?} is not set up here")), "{out}");
            assert!(out.contains("`cmux harness add ID --registry`"), "{out}");
        }
        assert_eq!(hint_text("bad".into(), "a b", &[], None), "bad");
    }

    #[test]
    fn real_model_id_still_suggests_claude_spelling() {
        assert!(looks_like_claude_model_id("claude-opus-5-5"));
        let hits = vec!["claude/claude-opus-5-5".to_owned()];
        let out = hint_text("unknown harness".into(), "claude-opus-5-5", &hits, Some("claude"));
        assert!(
            out.contains("\"claude-opus-5-5\" is a model id: write claude/claude-opus-5-5"),
            "{out}"
        );
    }

    #[test]
    fn other_names_keep_the_bare_error() {
        assert_eq!(
            hint_text("unknown harness \"gpt\"".into(), "gpt", &[], None),
            "unknown harness \"gpt\""
        );
    }
}
