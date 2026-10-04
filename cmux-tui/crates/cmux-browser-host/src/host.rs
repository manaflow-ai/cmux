//! REPL sessions on one machine: the `browser.repl.*` catalog ops.
//!
//! A session is a VM ([`crate::vm::VmSession`]) behind its own policy gate
//! ([`crate::gate::Gate`]). Sessions keep their VM state between calls until
//! `close`, `reset` or a host restart. Every call carries `origin` and the
//! actor the listener derived from the connection; both go to the action log.

use crate::driver::Driver;
use crate::gate::{Gate, Grants};
use crate::protocol::{DriverError, DriverEvent, ErrorCode};
use crate::vm::{VmConfig, VmSession};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

/// Generated from js/manifest.json by build.rs.
pub mod bundle {
    include!(concat!(env!("OUT_DIR"), "/js_bundle.rs"));
}

/// The page agent bundle, installed in every frame's agent world. Recipe
/// from #15570 (tests/browser-parity/lib/dev-driver.mjs agentInstallSource):
/// Playwright's injected script is a CommonJS module whose `InjectedScript`
/// factory page-agent.js reads.
pub fn agent_bundle() -> String {
    let source = |name: &str| {
        bundle::AGENT_SCRIPTS.iter().find(|(file, _)| *file == name).map(|(_, s)| *s).unwrap_or("")
    };
    format!(
        "(() => {{\nconst module = {{}};\n{}\n;const __cmuxInjectedScriptFactory = module.exports.InjectedScript;\n{}\n}})()",
        source("vendor/playwright-injected.js"),
        source("page-agent.js")
    )
}

/// Default limits of one session.
pub const DEFAULT_EVAL_TIMEOUT: Duration = Duration::from_secs(120);
pub const DEFAULT_MEMORY_LIMIT: usize = 1 << 30;
pub const DEFAULT_MAX_OUTPUT: usize = 20_000;

/// Who sent a request (from the connection, never from the request body).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Caller {
    pub actor: String,
    pub on_behalf_of: Option<String>,
    /// `user | cli | mcp | script | remote`.
    pub origin: String,
}

/// Opens engines on demand.
pub trait Engines: Send + Sync {
    /// The driver for `engine` (`auto`, `headless`, `cef`, `webkit`); the
    /// sink receives that driver's events.
    fn driver(
        &self,
        engine: &str,
        events: crate::driver::EventSink,
        session: &SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError>;
}

/// The session an engine is opened for (lease identity on provider tabs).
#[derive(Debug, Clone)]
pub struct SessionContext {
    pub name: String,
    pub caller: Caller,
    /// The agent's task label (`browser.repl.open {label}`), the lease badge text.
    pub label: String,
    /// The browser profile (`browser.repl.open {profile}`): `agent` (the
    /// per-workspace agent profile, D12) unless the person picked another.
    pub profile: String,
}

/// The profile agents get unless the person names another (D12).
pub const AGENT_PROFILE: &str = "agent";

type EventSlot = Arc<Mutex<Option<(Arc<Gate>, std::sync::mpsc::Sender<DriverEvent>)>>>;

struct Session {
    vm: VmSession,
    gate: Arc<Gate>,
    /// Breaks the driver -> sink -> gate -> driver cycle on close.
    events: EventSlot,
    engine: String,
    created_by: Caller,
}

pub struct Host {
    engines: Arc<dyn Engines>,
    cwd: String,
    sessions: Mutex<BTreeMap<String, Arc<Session>>>,
    /// Serializes opens, so two opens of one name never start two engines.
    opening: Mutex<()>,
    /// Secrets any session typed into a tab (masked for every session).
    tab_secrets: Arc<crate::secrets::TabSecrets>,
}

impl Host {
    pub fn new(engines: Arc<dyn Engines>, cwd: impl Into<String>) -> Host {
        Host {
            engines,
            cwd: cwd.into(),
            sessions: Mutex::new(BTreeMap::new()),
            opening: Mutex::new(()),
            tab_secrets: Arc::default(),
        }
    }

    fn sessions(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, Arc<Session>>> {
        self.sessions.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Runs one catalog op.
    pub fn dispatch(
        &self,
        caller: &Caller,
        method: &str,
        params: &Value,
    ) -> Result<Value, DriverError> {
        match method {
            "browser.repl.open" => self.open(caller, params),
            "browser.repl.eval" => self.eval(caller, params),
            "browser.repl.close" => self.close(params),
            "browser.repl.reset" => {
                self.close(params)?;
                self.open(caller, params)
            }
            "browser.repl.list" => Ok(self.list()),
            "browser.repl.guide" => Ok(json!({"guide": bundle::GUIDE})),
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    /// The person's tabs (cef, webkit) carry automation leases keyed by the
    /// session, so the implicit shared `default` session is refused there.
    fn require_named_session(engine: &str, params: &Value) -> Result<(), DriverError> {
        let named = params
            .get("session")
            .and_then(Value::as_str)
            .is_some_and(|name| !name.is_empty() && name != "default");
        if matches!(engine, "cef" | "webkit") && !named {
            return Err(DriverError::invalid(format!(
                "session: {engine} sessions drive the person's tabs and need an explicit session name"
            )));
        }
        Ok(())
    }

    fn session_name(params: &Value) -> Result<String, DriverError> {
        let name = params.get("session").and_then(Value::as_str).unwrap_or("default");
        let valid = !name.is_empty()
            && name.len() <= 64
            && name.chars().all(|c| c.is_ascii_alphanumeric() || "_.-".contains(c));
        if !valid {
            return Err(DriverError::invalid(format!(
                "session: expected letters, digits, _, . or - (at most 64), got {name:?}"
            )));
        }
        Ok(name.to_owned())
    }

    /// Creates the session, or attaches to it when it exists (idempotent by name).
    fn open(&self, caller: &Caller, params: &Value) -> Result<Value, DriverError> {
        let _opening = self.opening.lock().unwrap_or_else(PoisonError::into_inner);
        let name = Self::session_name(params)?;
        let engine = params.get("engine").and_then(Value::as_str).unwrap_or("auto").to_owned();
        Self::require_named_session(&engine, params)?;
        if let Some(existing) = self.sessions().get(&name) {
            if engine != "auto" && engine != existing.engine {
                return Err(DriverError::invalid(format!(
                    "session {name} runs on {}; close it to change the engine",
                    existing.engine
                )));
            }
            return Ok(json!({"session": name, "engine": existing.engine, "created": false}));
        }
        let raw_cdp = params.get("rawCdp").and_then(Value::as_bool).unwrap_or(false);
        if raw_cdp && caller.origin != "user" {
            return Err(DriverError::new(ErrorCode::Forbidden, "raw CDP needs a user grant"));
        }
        // Events reach the session through a slot filled after the VM exists.
        let slot: EventSlot = Arc::new(Mutex::new(None));
        let sink_slot = slot.clone();
        let sink: crate::driver::EventSink = Arc::new(move |event: DriverEvent| {
            if let Some((gate, tx)) =
                sink_slot.lock().unwrap_or_else(PoisonError::into_inner).as_ref()
            {
                let payload = gate.mask_event(&event.name, &event.payload);
                let _ = tx.send(DriverEvent { name: event.name, payload });
            }
        });
        // Only the person (user origin) opens a session on another profile,
        // such as their signed-in one (D12); agents get the agent profile.
        let profile = params.get("profile").and_then(Value::as_str).unwrap_or(AGENT_PROFILE);
        if profile != AGENT_PROFILE && caller.origin != "user" {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                format!(
                    "profile {profile:?}: only the person opens a session on a profile other than {AGENT_PROFILE:?}"
                ),
            ));
        }
        let context = SessionContext {
            name: name.clone(),
            caller: caller.clone(),
            label: lease_label(params.get("label").and_then(Value::as_str), &name),
            profile: profile.to_owned(),
        };
        let driver = self.engines.driver(&engine, sink, &context)?;
        let mut capabilities: Vec<String> =
            driver.capabilities().into_iter().map(str::to_owned).collect();
        // The gate types `input.insertText { secret }` for every engine.
        if !capabilities.iter().any(|c| c == "secret.insert") {
            capabilities.push("secret.insert".into());
        }
        let gate = Arc::new(
            Gate::new(driver, Grants { raw_cdp }).with_tab_secrets(self.tab_secrets.clone()),
        );
        let config = VmConfig {
            session_id: name.clone(),
            cwd: session_root(params.get("cwd").and_then(Value::as_str), &self.cwd, &name),
            memory_limit: DEFAULT_MEMORY_LIMIT,
            capabilities,
            scripts: bundle::REPL_SCRIPTS
                .iter()
                .map(|(f, s)| ((*f).to_owned(), (*s).to_owned()))
                .collect(),
            resources: bundle::REPL_SCRIPTS
                .iter()
                .chain(bundle::AGENT_SCRIPTS.iter())
                .map(|(f, s)| ((*f).to_owned(), (*s).to_owned()))
                .chain(std::iter::once(("guide.md".to_owned(), bundle::GUIDE.to_owned())))
                .collect(),
        };
        let vm = VmSession::spawn(config, gate.clone())
            .map_err(|e| DriverError::closed(format!("could not start the session: {e}")))?;
        // Forward masked driver events into the VM from one thread per session.
        let (tx, rx) = std::sync::mpsc::channel::<DriverEvent>();
        let events_vm = vm.events();
        std::thread::Builder::new()
            .name(format!("cmux-browser-host-events-{name}"))
            .spawn(move || {
                for event in rx {
                    events_vm.event(&event.name, event.payload);
                }
            })
            .map_err(|e| DriverError::closed(format!("could not start the session: {e}")))?;
        *slot.lock().unwrap_or_else(PoisonError::into_inner) = Some((gate.clone(), tx));
        let resolved = if engine == "auto" { "headless".to_owned() } else { engine };
        self.sessions().insert(
            name.clone(),
            Arc::new(Session {
                vm,
                gate,
                events: slot,
                engine: resolved.clone(),
                created_by: caller.clone(),
            }),
        );
        Ok(json!({"session": name, "engine": resolved, "created": true}))
    }

    fn eval(&self, caller: &Caller, params: &Value) -> Result<Value, DriverError> {
        let name = Self::session_name(params)?;
        let code = params
            .get("code")
            .and_then(Value::as_str)
            .ok_or_else(|| DriverError::invalid("code: expected a string"))?;
        let session = match self.sessions().get(&name).cloned() {
            Some(session) => session,
            None => {
                self.open(caller, params)?;
                self.sessions()
                    .get(&name)
                    .cloned()
                    .ok_or_else(|| DriverError::closed(format!("session {name} closed")))?
            }
        };
        let timeout = params
            .get("timeoutMs")
            .and_then(Value::as_u64)
            .map(Duration::from_millis)
            .unwrap_or(DEFAULT_EVAL_TIMEOUT);
        // Characters, applied by the runtime (which spills the rest to a
        // file and says so); 0 means no limit.
        let max_output = params
            .get("maxOutput")
            .and_then(Value::as_u64)
            .map(|n| n as usize)
            .unwrap_or(DEFAULT_MAX_OUTPUT);
        let started = std::time::Instant::now();
        let outcome = session.vm.eval_with(code, timeout, &json!({"maxOutput": max_output}));
        let duration_ms = started.elapsed().as_millis() as u64;
        let mut stream = session.gate.masker().stream();
        let mut text = String::new();
        for (_, line) in &outcome.output {
            text.push_str(&stream.write(line));
            text.push_str(&stream.write("\n"));
        }
        text.push_str(&stream.finish());
        // A backstop above the runtime's own cap (UTF-8 bytes per character).
        let truncated =
            max_output != 0 && cap(&mut text, max_output.saturating_mul(4).saturating_add(1024));
        let mut error = outcome.error.map(|e| session.gate.mask(&e));
        // A timed-out cell can leave the runtime waiting on it forever, so
        // every later cell would queue behind it: start the session afresh.
        if error.as_deref().is_some_and(|e| e.contains("evaluation timed out")) {
            self.close(&json!({"session": name}))?;
            if let Some(text) = &mut error {
                text.push_str(
                    "\n(the session was reset: its variables and tabs ended with this cell)",
                );
            }
        }
        Ok(json!({
            "session": name,
            "output": text,
            "truncated": truncated,
            "error": error,
            "durationMs": duration_ms,
            "createdBy": session.created_by.actor,
        }))
    }

    fn close(&self, params: &Value) -> Result<Value, DriverError> {
        let name = Self::session_name(params)?;
        let removed = self.sessions().remove(&name);
        if let Some(session) = &removed {
            *session.events.lock().unwrap_or_else(PoisonError::into_inner) = None;
            // The leases go now: a reset reopens this name at once, and the
            // old engine may live on until an eval in flight returns.
            session.gate.end_session();
        }
        let removed = removed.is_some();
        Ok(json!({"session": name, "closed": removed}))
    }

    fn list(&self) -> Value {
        Value::Array(
            self.sessions()
                .iter()
                .map(|(name, s)| json!({"session": name, "engine": s.engine, "createdBy": s.created_by.actor, "origin": s.created_by.origin}))
                .collect(),
        )
    }
}

/// The fs root for a session: the caller's directory when it is a real,
/// narrow directory (not `/`, not the home directory or an ancestor of it),
/// else a private directory for the session under the host's state.
fn session_root(caller: Option<&str>, fallback_base: &str, session: &str) -> String {
    let broad = |path: &std::path::Path| {
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .and_then(|h| h.canonicalize().ok());
        path == std::path::Path::new("/") || home.as_deref().is_some_and(|h| h.starts_with(path))
    };
    if let Some(dir) = caller.map(std::path::Path::new).filter(|p| p.is_absolute())
        && let Ok(real) = dir.canonicalize()
        && real.is_dir()
        && !broad(&real)
    {
        return real.display().to_string();
    }
    let _ = fallback_base;
    std::env::temp_dir().join("cmux-browser-host").join("roots").join(session).display().to_string()
}

/// The lease badge text: the agent's label without control or invisible
/// format characters, whitespace collapsed, at most 48 characters; the
/// session name when nothing is left. The app shows it after a fixed prefix.
fn lease_label(label: Option<&str>, session: &str) -> String {
    let invisible = |c: char| {
        c.is_control()
            || matches!(c,
                '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{200B}'..='\u{200F}'
                | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{206F}' | '\u{FEFF}'
                | '\u{FFF9}'..='\u{FFFB}' | '\u{E0000}'..='\u{E007F}')
    };
    let words: Vec<String> = label
        .unwrap_or("")
        .split(char::is_whitespace)
        .map(|word| word.chars().filter(|c| !invisible(*c)).collect::<String>())
        .filter(|word| !word.is_empty())
        .collect();
    let text: String = words.join(" ").chars().take(48).collect();
    let text = text.trim_end();
    if text.is_empty() { session.to_owned() } else { text.to_owned() }
}

/// Cuts `text` to at most `max` bytes on a character boundary; true when cut.
fn cap(text: &mut String, max: usize) -> bool {
    if text.len() <= max {
        return false;
    }
    let mut cut = max;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    let dropped = text.len() - cut;
    text.truncate(cut);
    text.push_str(&format!("\n… {dropped} more bytes (raise maxOutput)"));
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An engine that records the profile each session was opened with and
    /// answers no driver call.
    struct ProfileEngines(Mutex<Vec<String>>);

    struct NoDriver;

    impl Driver for NoDriver {
        fn call(&self, method: &str, _: &Value) -> Result<Value, DriverError> {
            Err(DriverError::unsupported_method(method))
        }

        fn capabilities(&self) -> Vec<&'static str> {
            Vec::new()
        }
    }

    impl Engines for ProfileEngines {
        fn driver(
            &self,
            _engine: &str,
            _events: crate::driver::EventSink,
            session: &SessionContext,
        ) -> Result<Arc<dyn Driver>, DriverError> {
            self.0.lock().unwrap().push(session.profile.clone());
            Ok(Arc::new(NoDriver))
        }
    }

    #[test]
    fn engines_get_the_session_profile_and_only_the_person_picks_another() {
        let engines = Arc::new(ProfileEngines(Mutex::new(Vec::new())));
        let root = std::env::temp_dir().join(format!("profile-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let host = Host::new(engines.clone(), root.display().to_string());
        let caller = |origin: &str| Caller {
            actor: "uid:501".into(),
            on_behalf_of: None,
            origin: origin.into(),
        };
        host.dispatch(
            &caller("mcp"),
            "browser.repl.open",
            &json!({"session": "a", "engine": "headless"}),
        )
        .unwrap();
        let refused = host
            .dispatch(
                &caller("mcp"),
                "browser.repl.open",
                &json!({"session": "b", "engine": "headless", "profile": "signed-in"}),
            )
            .unwrap_err();
        assert_eq!(refused.code, ErrorCode::Forbidden, "{refused}");
        host.dispatch(
            &caller("user"),
            "browser.repl.open",
            &json!({"session": "c", "engine": "headless", "profile": "signed-in"}),
        )
        .unwrap();
        assert_eq!(*engines.0.lock().unwrap(), vec!["agent".to_owned(), "signed-in".to_owned()]);
        for name in ["a", "c"] {
            let _ = host.dispatch(&caller("user"), "browser.repl.close", &json!({"session": name}));
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn output_caps_on_char_boundaries() {
        let mut text = "héllo".repeat(10);
        assert!(cap(&mut text, 7));
        assert!(text.starts_with("héllo"));
        let mut short = "ok".to_owned();
        assert!(!cap(&mut short, 7));
    }

    #[test]
    fn broad_caller_directories_get_a_private_root() {
        let home = std::env::var("HOME").unwrap();
        assert!(session_root(Some("/"), "/", "s").contains("cmux-browser-host"));
        assert!(session_root(Some(&home), "/", "s").contains("cmux-browser-host"));
        assert!(session_root(Some("relative/dir"), "/", "s").contains("cmux-browser-host"));
        let narrow = std::env::temp_dir().join(format!("narrow-{}", std::process::id()));
        std::fs::create_dir_all(&narrow).unwrap();
        assert_eq!(
            session_root(Some(narrow.to_str().unwrap()), "/", "s"),
            narrow.canonicalize().unwrap().display().to_string()
        );
    }

    #[test]
    fn lease_labels_are_cleaned_and_capped() {
        assert_eq!(lease_label(Some("Book  a\nflight"), "s"), "Book a flight");
        assert_eq!(lease_label(Some("\u{202E}evil\u{200B}\u{0007}"), "s"), "evil");
        assert_eq!(lease_label(Some(" \u{FEFF} "), "s1"), "s1");
        assert_eq!(lease_label(None, "s1"), "s1");
        assert_eq!(lease_label(Some(&"x".repeat(200)), "s").chars().count(), 48);
    }

    #[test]
    fn the_persons_tabs_need_a_named_session() {
        for engine in ["cef", "webkit"] {
            assert!(Host::require_named_session(engine, &json!({})).is_err(), "{engine}");
            let null = json!({"session": null});
            assert!(Host::require_named_session(engine, &null).is_err());
            let default = json!({"session": "default"});
            assert!(Host::require_named_session(engine, &default).is_err());
            assert!(Host::require_named_session(engine, &json!({"session": "a"})).is_ok());
        }
        assert!(Host::require_named_session("headless", &json!({})).is_ok());
        assert!(Host::require_named_session("auto", &json!({})).is_ok());
    }

    #[test]
    fn session_names_are_checked() {
        assert!(Host::session_name(&json!({"session": "a.b-c_1"})).is_ok());
        assert_eq!(Host::session_name(&json!({})).unwrap(), "default");
        assert!(Host::session_name(&json!({"session": "../x"})).is_err());
    }

    #[test]
    fn the_bundle_holds_the_manifest_scripts() {
        assert!(bundle::REPL_SCRIPTS.iter().any(|(f, _)| *f == "repl-host.js"));
        assert_eq!(bundle::AGENT_SCRIPTS.last().map(|(f, _)| *f), Some("page-agent.js"));
        assert!(agent_bundle().contains("cmux"));
    }

    #[test]
    fn the_agent_bundle_wraps_playwright_injected_as_a_module() {
        // The #15570 install recipe (tests/browser-parity/lib/dev-driver.mjs
        // agentInstallSource): Playwright's injected script is a CommonJS
        // module, and page-agent.js reads its factory.
        let bundle = agent_bundle();
        assert!(bundle.starts_with("(() => {\nconst module = {};\n"), "{}", &bundle[..80]);
        assert!(
            bundle
                .contains(";const __cmuxInjectedScriptFactory = module.exports.InjectedScript;\n")
        );
        assert!(bundle.trim_end().ends_with("})()"));
        assert!(!bundle::GUIDE.is_empty());
    }
}
