//! A session that takes over another's work keeps that session's harness (HQ#5266, item 3).
//!
//! Leo, 2026-10-30: "that visibility into huge-blue guys was (and is?) pretty bad". Four
//! deputies were relaunched with only `area` and `role` tags: each came back on the bare
//! `claude` default instead of its `claude-sr2` profile, without the autocompact cap, and ran
//! that way for hours. Nothing said so.
//!
//! A `session/new` names a predecessor when it has, first match wins:
//! - `_meta.acpmux.harnessFrom` (`acpmux new|ensure --harness-from P`): P's harness is copied;
//! - a `succeeds=P` tag;
//! - `--report-to P` (`_meta.acpmux.reportTo`) or a lineage parent P whose name is of its own
//!   name family (`dep-fleet-2` started by `dep-fleet`);
//! - a `NAME-N` name (N of one or two digits): the newest other session named NAME or NAME-K;
//! - an `area=A` tag: the newest other session with that area, live or updated in the last
//!   week; one with the same `role=` tag first.
//!
//! Then:
//! - with no `-m`, preset or `--harness-from`, it would start on the default harness, and the
//!   predecessor ran a named profile (not what its family's name resolves to): refused, naming
//!   both and the flags that keep or overrule it. Not for an area match alone: a coordinator's
//!   helpers share an area and are each other's siblings, not successors; the same role too
//!   (the deputies' `area` and `role`) refuses;
//! - once made, when its profile, launcher, model, effort or autocompact cap differs from the
//!   predecessor's: a one-line warning in the reply (`_meta.acpmux.successor`), which the CLI
//!   prints.
//!
//! One pass over the session index under its lock; no transcript is read.

use super::*;
use std::collections::BTreeMap;

/// `_meta.acpmux` field: the session whose harness this one copies.
pub const HARNESS_FROM_FIELD: &str = "harnessFrom";
/// `_meta.acpmux` field: the session `--report-to` names.
pub const REPORT_TO_FIELD: &str = "reportTo";
/// The tag that names the session this one takes over from.
pub const SUCCEEDS_TAG: &str = "succeeds";
/// A closed session counts as an area's predecessor this long after its last change.
const RECENT_MS: u64 = 7 * 24 * 3600 * 1000;

/// What made a session the predecessor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Via {
    HarnessFrom,
    Succeeds,
    ReportTo,
    Parent,
    NameFamily,
    Area(String),
    /// The same area and role.
    AreaRole(String, String),
}

impl Via {
    fn describe(&self) -> String {
        match self {
            Via::HarnessFrom => "--harness-from".into(),
            Via::Succeeds => format!("tag {SUCCEEDS_TAG}="),
            Via::ReportTo => "--report-to".into(),
            Via::Parent => "its starter".into(),
            Via::NameFamily => "its name".into(),
            Via::Area(a) => format!("area={a}"),
            Via::AreaRole(a, r) => format!("area={a} role={r}"),
        }
    }
}

/// The predecessor a `session/new` names, and the harness `--harness-from` copies from it.
#[derive(Debug, Clone)]
pub struct Successor {
    pub predecessor: SessionMeta,
    pub via: Via,
    pub copy: Option<HarnessCopy>,
}

/// The request values `--harness-from` sets: the predecessor's exact profile, preset, model
/// and effort.
#[derive(Debug, Clone, Default)]
pub struct HarnessCopy {
    pub harness: Option<String>,
    pub preset: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
}

/// The newest session found so far, by its last change.
type Newest = Option<(u64, Arc<Session>)>;

/// The candidates of one pass over the session index, one per way of naming a predecessor.
#[derive(Default)]
struct Found {
    succeeds: Option<Arc<Session>>,
    report_to: Option<Arc<Session>>,
    parent: Option<Arc<Session>>,
    family: Newest,
    role: Newest,
    area: Newest,
}

/// What a session runs on, as compared between a successor and its predecessor.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Shape {
    profile: String,
    launcher: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    autocompact: Option<String>,
}

/// `NAME` of `NAME-N` (N of one or two digits), else the name itself. A longer number is an
/// id (`review-27903`), not a generation.
pub fn name_family(name: &str) -> &str {
    match name.rsplit_once('-') {
        Some((base, n))
            if !base.is_empty()
                && (1..=2).contains(&n.len())
                && n.bytes().all(|b| b.is_ascii_digit()) =>
        {
            base
        }
        _ => name,
    }
}

/// The autocompact cap a session runs with: `--autocompact N` in its argv, or an env entry
/// whose key names autocompact, from its profile, preset or family defaults.
fn autocompact(argv: &[String], envs: &[&BTreeMap<String, String>]) -> Option<String> {
    let mut args = argv.iter();
    while let Some(a) = args.next() {
        if let Some(v) = a.strip_prefix("--autocompact=") {
            return Some(v.to_owned());
        }
        if a == "--autocompact" {
            return Some(args.next().cloned().unwrap_or_else(|| "on".into()));
        }
    }
    envs.iter().flat_map(|e| e.iter()).find_map(|(k, v)| {
        let key = k.to_ascii_uppercase().replace('_', "");
        key.contains("AUTOCOMPACT").then(|| format!("{k}={v}"))
    })
}

fn shape(m: &SessionMeta, cfg: &Config) -> Shape {
    let argv = m.spawn_argv.as_deref().unwrap_or(&m.harness_argv);
    let profile_env = cfg.harnesses.get(&m.harness).map(|p| &p.env);
    let preset_env = m.preset.as_ref().and_then(|p| cfg.presets.get(p)).map(|p| &p.env);
    let defaults = cfg.defaults_for(&m.harness);
    let envs: Vec<&BTreeMap<String, String>> =
        [profile_env, preset_env, Some(&defaults.env)].into_iter().flatten().collect();
    Shape {
        profile: m.harness.clone(),
        // What it ran last (a launcher reload or a fallback since may have changed it).
        launcher: argv.first().cloned(),
        model: current_model(m),
        effort: current_effort(m).or_else(|| current_option(m, "reasoning_effort")),
        autocompact: autocompact(argv, &envs),
    }
}

/// What `--harness-from` copies of `m`: its profile, preset, model and effort as it runs now.
fn harness_copy(m: &SessionMeta) -> HarnessCopy {
    HarnessCopy {
        harness: Some(m.harness.clone()),
        preset: m.preset.clone(),
        model: current_model(m),
        // Claude's Ultracode is an effort here (`claude_stdio` takes `effort=ultracode`).
        effort: current_effort(m).or_else(|| current_option(m, "reasoning_effort")),
    }
}

/// `field old -> new` for each compared field that differs. A value one side does not know
/// yet is not called a difference.
fn differences(was: &Shape, now: &Shape) -> Vec<String> {
    let opt = |v: &Option<String>| v.clone().unwrap_or_else(|| "none".into());
    let mut out = Vec::new();
    if was.profile != now.profile {
        out.push(format!("harness {} -> {}", was.profile, now.profile));
    }
    if was.launcher != now.launcher {
        out.push(format!("launcher {} -> {}", opt(&was.launcher), opt(&now.launcher)));
    }
    for (what, a, b) in [("model", &was.model, &now.model), ("effort", &was.effort, &now.effort)] {
        if a.is_some() && b.is_some() && a != b {
            out.push(format!("{what} {} -> {}", opt(a), opt(b)));
        }
    }
    if was.autocompact != now.autocompact {
        out.push(format!("autocompact {} -> {}", opt(&was.autocompact), opt(&now.autocompact)));
    }
    out
}

/// A `session/new` value, from `_meta.acpmux` first, then the params.
fn pick(params: &Value, meta: Option<&Value>, key: &str) -> Option<String> {
    meta.and_then(|m| m.get(key))
        .or_else(|| params.get(key))
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
}

fn tag<'a>(meta: Option<&'a Value>, key: &str) -> Option<&'a str> {
    meta.and_then(|m| m.pointer(&format!("/tags/{key}")))
        .and_then(|v| v.as_str().or_else(|| v.get("value").and_then(Value::as_str)))
        .filter(|v| !v.is_empty())
}

impl Hub {
    /// The predecessor a `session/new` names (see the module doc), or None. Refused: a
    /// `--harness-from` that names no session or comes with `-m`, `-p` or `-e`, and a bare
    /// default start where the predecessor ran a named profile. The caller refuses a
    /// `--harness-from` from any connection but the local socket (`server/requests/successor.rs`).
    pub async fn successor(
        &self,
        params: &Value,
        meta: Option<&Value>,
        lineage: Option<&Lineage>,
    ) -> Result<Option<Successor>, RpcError> {
        let asked = |k: &str| pick(params, meta, k);
        if let Some(from) = asked(HARNESS_FROM_FIELD) {
            if let Some(k) =
                ["harness", "preset", "model", "effort"].into_iter().find(|k| asked(k).is_some())
            {
                return Err(RpcError::invalid_params(format!(
                    "--harness-from copies the harness, preset, model and effort; it takes no {k}"
                )));
            }
            let p = self
                .resolve(&from)
                .map_err(|_| RpcError::not_found(format!("--harness-from: no session {from:?}")))?;
            let predecessor = p.meta();
            let copy = harness_copy(&predecessor);
            return Ok(Some(Successor { predecessor, via: Via::HarnessFrom, copy: Some(copy) }));
        }
        let name = asked("name");
        let Some((predecessor, via)) = self.predecessor(meta, name.as_deref(), lineage, &asked)
        else {
            return Ok(None);
        };
        let bare =
            asked("harness").is_none() && asked("preset").is_none() && asked("model").is_none();
        if bare && !matches!(via, Via::Area(_)) {
            self.refuse_bare_default(name.as_deref(), &predecessor, &via).await?;
        }
        Ok(Some(Successor { predecessor, via, copy: None }))
    }

    /// The predecessor by tag, report-to, starter, name or area, in that order, from one pass
    /// over the session index. `succeeds=` and `--report-to` name a session by its id or name.
    fn predecessor(
        &self,
        meta: Option<&Value>,
        name: Option<&str>,
        lineage: Option<&Lineage>,
        asked: &dyn Fn(&str) -> Option<String>,
    ) -> Option<(SessionMeta, Via)> {
        let succeeds = tag(meta, SUCCEEDS_TAG);
        let report_to = asked(REPORT_TO_FIELD);
        let parent = lineage.map(|l| l.parent.as_str());
        let family = name.map(name_family);
        let by_name = name.filter(|n| name_family(n) != *n).map(name_family);
        let (area, role) = (tag(meta, "area"), tag(meta, "role"));
        let any = [succeeds, report_to.as_deref(), parent, by_name, area];
        if any.iter().all(Option::is_none) {
            return None;
        }
        let since = now_ms().saturating_sub(RECENT_MS);
        let mut found = Found::default();
        let newer = |best: &Newest, at: u64| best.as_ref().is_none_or(|(b, _)| at > *b);
        for s in self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).values() {
            let m = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let is = |key: Option<&str>| key.is_some_and(|k| s.id == k || m.name == k);
            if is(succeeds) {
                found.succeeds = Some(s.clone());
            }
            let same_family = family.is_some_and(|f| name_family(&m.name) == f);
            // A session's starter, or the one it reports to, stays at its own work: its
            // predecessor only when of its name family, never by name or area.
            let report = is(report_to.as_deref());
            let starter = parent == Some(s.id.as_str());
            if report && same_family {
                found.report_to = Some(s.clone());
            }
            if starter && same_family {
                found.parent = Some(s.clone());
            }
            if report || starter || Some(m.name.as_str()) == name {
                continue;
            }
            if by_name.is_some_and(|f| name_family(&m.name) == f)
                && newer(&found.family, m.updated_at)
            {
                found.family = Some((m.updated_at, s.clone()));
            }
            let live = m.status != SessionStatus::Closed || m.updated_at >= since;
            let has = |k: &str, v: Option<&str>| {
                v.is_some_and(|v| m.tags.get(k).is_some_and(|t| t.value == v))
            };
            if live && has("area", area) {
                if newer(&found.area, m.updated_at) {
                    found.area = Some((m.updated_at, s.clone()));
                }
                if has("role", role) && newer(&found.role, m.updated_at) {
                    found.role = Some((m.updated_at, s.clone()));
                }
            }
        }
        let area = area.unwrap_or_default().to_owned();
        let role = role.unwrap_or_default().to_owned();
        [
            (found.succeeds, Via::Succeeds),
            (found.report_to, Via::ReportTo),
            (found.parent, Via::Parent),
            (found.family.map(|(_, s)| s), Via::NameFamily),
            (found.role.map(|(_, s)| s), Via::AreaRole(area.clone(), role)),
            (found.area.map(|(_, s)| s), Via::Area(area)),
        ]
        .into_iter()
        .find_map(|(s, via)| s.map(|s| (s.meta(), via)))
    }

    /// Refuses a start on the bare default harness when the predecessor ran a named profile
    /// that the default does not resolve to.
    async fn refuse_bare_default(
        &self,
        name: Option<&str>,
        predecessor: &SessionMeta,
        via: &Via,
    ) -> Result<(), RpcError> {
        let cfg = self.config.read().await;
        let Some(default) =
            cfg.default_harness.as_deref().and_then(|h| cfg.resolve_harness(h).ok())
        else {
            return Ok(());
        };
        let was = &predecessor.harness;
        let family = predecessor.family.as_deref().unwrap_or(was);
        let named_profile = cfg.resolve_harness(family).ok().as_deref() != Some(was.as_str());
        if !named_profile || default == *was {
            return Ok(());
        }
        let p = &predecessor.name;
        Err(RpcError::invalid_params(format!(
            "{} would start on the default harness {default}, but its predecessor {p} \
             (by {}) ran {was}; pass --harness-from {p} to keep {was}, \
             or -m {default} to start on {default} on purpose",
            name.unwrap_or("this session"),
            via.describe(),
        ))
        .with_data(json!({
            "reason": "successor.harness_dropped",
            "predecessor": p,
            "predecessorHarness": was,
            "harness": default,
        })))
    }

    /// The warning for `session` started as `successor`'s successor: None when it runs on what
    /// its predecessor ran. With `--harness-from`, what the copy could not keep (a launcher or
    /// cap its profile no longer has).
    pub async fn successor_warning(
        &self,
        successor: &Successor,
        session: &Session,
    ) -> Option<Value> {
        let now = session.meta();
        let cfg = self.config.read().await;
        let diff = differences(&shape(&successor.predecessor, &cfg), &shape(&now, &cfg));
        if diff.is_empty() {
            return None;
        }
        let p = &successor.predecessor.name;
        let keep = match successor.via {
            Via::HarnessFrom => format!("{p}'s profile has changed since it started"),
            _ => format!("--harness-from {p} keeps the original"),
        };
        let warning = format!(
            "{} runs unlike its predecessor {p} (by {}): {}; {keep}",
            now.name,
            successor.via.describe(),
            diff.join(", "),
        );
        let via = successor.via.describe();
        Some(json!({"predecessor": p, "via": via, "differences": diff, "warning": warning}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_family_strips_a_short_generation_only() {
        assert_eq!(name_family("dep-fleet-2"), "dep-fleet");
        assert_eq!(name_family("dep-fleet-12"), "dep-fleet");
        assert_eq!(name_family("dep-fleet"), "dep-fleet");
        assert_eq!(name_family("review-27903"), "review-27903");
        assert_eq!(name_family("-2"), "-2");
    }

    #[test]
    fn autocompact_reads_argv_then_env() {
        let argv = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            autocompact(&argv(&["claude", "--autocompact", "400000"]), &[]),
            Some("400000".into())
        );
        assert_eq!(
            autocompact(&argv(&["claude", "--autocompact=380000"]), &[]),
            Some("380000".into())
        );
        let env = BTreeMap::from([("SR2_AUTO_COMPACT_TOKENS".to_owned(), "400000".to_owned())]);
        assert_eq!(
            autocompact(&argv(&["claude"]), &[&env]),
            Some("SR2_AUTO_COMPACT_TOKENS=400000".into())
        );
        assert_eq!(autocompact(&argv(&["claude"]), &[]), None);
    }

    fn meta(options: Value) -> SessionMeta {
        serde_json::from_value(json!({
            "schema": META_SCHEMA, "id": "p", "name": "p", "harness": "claude-sr2", "cwd": "/tmp",
            "status": "idle", "createdAt": 1, "updatedAt": 1, "configOptions": options,
            "harnessArgv": ["claude"], "spawnArgv": ["sr2", "claude", "--autocompact", "400000"],
        }))
        .unwrap()
    }

    #[test]
    fn harness_from_copies_ultracode_and_codex_reasoning_effort() {
        let opt = |id: &str, v: &str| json!({"id": id, "currentValue": v});
        let claude = meta(json!([opt("effort", "xhigh"), opt("ultracode", "on")]));
        assert_eq!(harness_copy(&claude).effort.as_deref(), Some("ultracode"));
        assert_eq!(harness_copy(&claude).harness.as_deref(), Some("claude-sr2"));
        let codex = meta(json!([opt("reasoning_effort", "high")]));
        assert_eq!(harness_copy(&codex).effort.as_deref(), Some("high"));
    }

    #[test]
    fn the_launcher_and_cap_are_what_it_last_started_with() {
        let s = shape(&meta(json!([])), &Config::default());
        assert_eq!(s.launcher.as_deref(), Some("sr2"));
        assert_eq!(s.autocompact.as_deref(), Some("400000"));
    }

    #[test]
    fn an_unknown_model_or_effort_is_no_difference() {
        let s = |model: Option<&str>| Shape {
            profile: "claude".into(),
            launcher: Some("claude".into()),
            model: model.map(str::to_owned),
            effort: None,
            autocompact: None,
        };
        assert!(differences(&s(Some("opus")), &s(None)).is_empty());
        assert_eq!(differences(&s(Some("opus")), &s(Some("sonnet"))), vec!["model opus -> sonnet"]);
    }
}
