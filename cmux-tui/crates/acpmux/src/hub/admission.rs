//! Admission of a new session: whether this host has room for one more
//! (deputy-2, 2026-10-22). About 25 Codex reviewers started on huge-blue with
//! a raw `acpmux new` over reach went around lane-place's cap of 12, filled
//! the disk and pushed the load to 50-80. Every new session goes through the
//! daemon's create, so the daemon checks there, reading two files each time:
//!
//! - `~/.cache/worktree-reclaim/under-floor`, which worktree-reclaim writes
//!   while the disk is under its free-space floor: no new session at all;
//! - `lanes.max_lanes` of this machine in the fleet registry (`FLEET_REGISTRY`,
//!   else `~/.ssh/config.d/fleet-registry.json`, the copy `reach --install`
//!   renders): no new session while this host's live sessions (running,
//!   ready, waiting; a peer's are not counted) are at the cap.
//!
//! This machine is `FLEET_ORIGIN` when set, else the registry machine whose
//! name, `aliases` or origin `hostnames` match the host name, as `reach`
//! finds it. With no registry, or no `lanes` entry for this machine, a create
//! is admitted (a log line says why): acpmux outside the fleet is unchanged.
//! `_meta.acpmux.forceAdmit` (`acpmux new --force-admit`) admits past both,
//! and the daemon logs who asked and what it overrode. Only creates are
//! checked: a send, a resume, a restart, an adopted conversation, a side
//! chat (`btw.rs`) and a handoff target never are.

use super::*;

/// `data.reason` of a refusal; the CLI exits 5 on it (`cli/errors.rs`).
pub const REASON: &str = "admission_refused";
/// `_meta.acpmux` field that admits past the checks.
pub const FORCE_FIELD: &str = "forceAdmit";

const NO_REGISTRY: &str = "no fleet registry";

/// Why a create is refused, with what the refusal names.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Refusal {
    UnderFloor { flag: PathBuf },
    MaxLanes { live: usize, max: u64 },
}

impl Refusal {
    fn why(&self) -> &'static str {
        match self {
            Self::UnderFloor { .. } => "under_floor",
            Self::MaxLanes { .. } => "max_lanes",
        }
    }

    fn error(&self, host: &str) -> RpcError {
        let what = match self {
            Self::UnderFloor { flag } => format!(
                "{host}'s disk is under its free-space floor ({} exists): no new session until worktree-reclaim frees space",
                flag.display()
            ),
            Self::MaxLanes { live, max } => format!(
                "{host} runs {live} of max_lanes {max} live sessions (fleet registry): stop one or start the session on another host"
            ),
        };
        let mut data = json!({"reason": REASON, "why": self.why(), "retryable": true});
        if let Self::MaxLanes { live, max } = self {
            (data["live"], data["maxLanes"]) = (json!(live), json!(max));
        }
        RpcError::new(-32000, format!("{what}; --force-admit creates it anyway")).with_data(data)
    }
}

/// What the checks read, so a test can give its own.
pub(crate) struct Inputs<'a> {
    pub flag: Option<&'a Path>,
    pub registry: Option<&'a Value>,
    pub machine: Option<&'a str>,
    pub live: usize,
}

/// The refusal for `inputs`, and why a cap did not apply (for the log).
pub(crate) fn check(inputs: &Inputs<'_>) -> (Option<Refusal>, Option<String>) {
    if let Some(flag) = inputs.flag.filter(|f| f.exists()) {
        return (Some(Refusal::UnderFloor { flag: flag.to_path_buf() }), None);
    }
    let Some(registry) = inputs.registry else {
        return (None, Some(NO_REGISTRY.into()));
    };
    let Some(machine) = inputs.machine else {
        return (None, Some("this host is no registry machine".into()));
    };
    let Some(max) = registry
        .pointer(&format!(
            "/machines/{}/lanes/max_lanes",
            machine.replace('~', "~0").replace('/', "~1")
        ))
        .and_then(Value::as_u64)
    else {
        return (None, Some(format!("no lanes entry with max_lanes for {machine}")));
    };
    let refusal =
        (inputs.live as u64 >= max).then_some(Refusal::MaxLanes { live: inputs.live, max });
    (refusal, None)
}

/// The registry machine this host is (module docs), lowercase names compared.
pub(crate) fn machine_of(registry: &Value, origin: Option<&str>, host: &str) -> Option<String> {
    let machines = registry.get("machines").and_then(Value::as_object)?;
    if let Some(name) = origin.filter(|o| !o.is_empty()) {
        return machines.contains_key(name).then(|| name.to_owned());
    }
    let host = host.trim().to_lowercase();
    let short = host.split('.').next().unwrap_or_default().to_owned();
    let names = |key: &str| -> Vec<String> {
        let words = |v: Option<&Value>| -> Vec<String> {
            v.and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_lowercase)
                .collect()
        };
        let mut all = vec![key.to_lowercase()];
        all.extend(words(machines.get(key).and_then(|m| m.get("aliases"))));
        all.extend(words(registry.pointer(&format!("/origins/{key}/hostnames"))));
        all
    };
    machines.keys().find(|k| names(k).iter().any(|n| *n == host || *n == short)).cloned()
}

fn user_home() -> Option<PathBuf> {
    std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from)
}

fn registry_path() -> Option<PathBuf> {
    match std::env::var_os("FLEET_REGISTRY").filter(|p| !p.is_empty()) {
        Some(path) => Some(path.into()),
        None => user_home().map(|h| h.join(".ssh/config.d/fleet-registry.json")),
    }
}

impl Hub {
    /// This host's sessions whose harness runs.
    fn live_sessions(&self) -> usize {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        sessions
            .iter()
            .filter(|s| {
                matches!(
                    s.status(),
                    SessionStatus::Ready | SessionStatus::Running | SessionStatus::Waiting
                )
            })
            .count()
    }

    /// Whether a new session may start here (module docs).
    pub(crate) async fn admit_new(&self, ask: Ask<'_>) -> Result<(), RpcError> {
        let flag = user_home().map(|h| h.join(".cache/worktree-reclaim/under-floor"));
        let live = self.live_sessions();
        let (refusal, uncapped) = tokio::task::spawn_blocking(move || {
            let registry = registry_path().and_then(|p| match std::fs::read(&p) {
                Ok(bytes) => serde_json::from_slice::<Value>(&bytes)
                    .map_err(
                        |e| tracing::warn!(path = %p.display(), "fleet registry unreadable: {e}"),
                    )
                    .ok(),
                Err(_) => None,
            });
            let origin = std::env::var("FLEET_ORIGIN").ok();
            let machine = registry
                .as_ref()
                .and_then(|r| machine_of(r, origin.as_deref(), super::start_gate::host_label()));
            check(&Inputs {
                flag: flag.as_deref(),
                registry: registry.as_ref(),
                machine: machine.as_deref(),
                live,
            })
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
        // Outside the fleet (no registry) that is every create: only a fleet host's gap is logged.
        match uncapped {
            Some(why) if why == NO_REGISTRY => {
                tracing::debug!("session admitted with no lane cap: {why}")
            }
            Some(why) => tracing::info!("session admitted with no lane cap: {why}"),
            None => {}
        }
        let Some(refusal) = refusal else { return Ok(()) };
        let (who, why) = (ask.who, refusal.why());
        if ask.force {
            tracing::warn!(
                caller = who,
                why,
                live,
                "session/new admitted by force-admit past {refusal:?}"
            );
            return Ok(());
        }
        // The person's own new chat (cmux NEXT, or the person's key): the cap
        // is for agents, and the app has no override to pass.
        if ask.person {
            tracing::info!(
                caller = who,
                why,
                live,
                "session/new admitted for the person past {refusal:?}"
            );
            return Ok(());
        }
        tracing::info!(caller = who, why, live, "session/new refused: {refusal:?}");
        let host = if ask.local { super::start_gate::host_label() } else { "this machine" };
        Err(refusal.error(host))
    }
}

/// Who asks for a new session, for `Hub::admit_new`.
pub(crate) struct Ask<'a> {
    /// `_meta.acpmux.forceAdmit`: admitted past a refusal, logged.
    pub force: bool,
    /// The person asks (their app's pane, here or through a peer, or the person key).
    pub person: bool,
    /// The caller session or the connection, for the log.
    pub who: &'a str,
    /// The refusal may name this host (not a Web client).
    pub local: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn registry() -> Value {
        json!({
            "origins": {"air-blue": {"hostnames": ["air-blue", "air-blue.local", "macbook-air"]}},
            "machines": {
                "huge-blue": {"lanes": {"max_lanes": 12}},
                "air-blue": {"aliases": ["macbook-air"], "lanes": {"max_lanes": 3}},
                "cmux-lawrence": {},
            },
        })
    }

    #[test]
    fn this_machine_is_found_by_name_alias_or_origin_hostname() {
        let r = registry();
        assert_eq!(machine_of(&r, None, "huge-blue").as_deref(), Some("huge-blue"));
        assert_eq!(machine_of(&r, None, "Air-Blue.local").as_deref(), Some("air-blue"));
        assert_eq!(machine_of(&r, None, "MacBook-Air").as_deref(), Some("air-blue"));
        assert_eq!(machine_of(&r, None, "somewhere-else"), None);
        assert_eq!(machine_of(&r, Some("huge-blue"), "air-blue").as_deref(), Some("huge-blue"));
        assert_eq!(machine_of(&r, Some("nowhere"), "huge-blue"), None);
    }

    #[test]
    fn the_cap_refuses_at_max_lanes_and_the_flag_before_it() {
        let r = registry();
        let at = |machine: Option<&str>, live| {
            check(&Inputs { flag: None, registry: Some(&r), machine, live }).0
        };
        assert_eq!(at(Some("huge-blue"), 11), None);
        assert_eq!(at(Some("huge-blue"), 12), Some(Refusal::MaxLanes { live: 12, max: 12 }));
        assert_eq!(at(Some("cmux-lawrence"), 50), None, "no lanes entry: admitted");
        assert_eq!(at(None, 50), None, "not a registry machine: admitted");
        let none = check(&Inputs { flag: None, registry: None, machine: None, live: 99 });
        assert_eq!(none.0, None, "no registry: admitted");
        let dir = std::env::temp_dir().join(format!("acpmux-admission-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let flag = dir.join("under-floor");
        std::fs::write(&flag, "").unwrap();
        let (refusal, _) =
            check(&Inputs { flag: Some(&flag), registry: None, machine: None, live: 0 });
        assert_eq!(refusal, Some(Refusal::UnderFloor { flag: flag.clone() }));
        let missing = dir.join("absent");
        let (refusal, _) = check(&Inputs {
            flag: Some(&missing),
            registry: Some(&r),
            machine: Some("huge-blue"),
            live: 0,
        });
        assert_eq!(refusal, None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
