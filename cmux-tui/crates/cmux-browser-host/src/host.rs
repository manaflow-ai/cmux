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
    ) -> Result<Arc<dyn Driver>, DriverError>;
}

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
}

impl Host {
    pub fn new(engines: Arc<dyn Engines>, cwd: impl Into<String>) -> Host {
        Host { engines, cwd: cwd.into(), sessions: Mutex::new(BTreeMap::new()) }
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
        let name = Self::session_name(params)?;
        let engine = params.get("engine").and_then(Value::as_str).unwrap_or("auto").to_owned();
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
                let payload = gate.mask_value(&event.payload);
                let _ = tx.send(DriverEvent { name: event.name, payload });
            }
        });
        let driver = self.engines.driver(&engine, sink)?;
        let capabilities = driver.capabilities().into_iter().map(str::to_owned).collect();
        let gate = Arc::new(Gate::new(driver, Grants { raw_cdp }));
        let config = VmConfig {
            session_id: name.clone(),
            cwd: self.cwd.clone(),
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
        let max_output = params
            .get("maxOutput")
            .and_then(Value::as_u64)
            .map(|n| n as usize)
            .unwrap_or(DEFAULT_MAX_OUTPUT);
        let started = std::time::Instant::now();
        let outcome = session.vm.eval(code, timeout);
        let duration_ms = started.elapsed().as_millis() as u64;
        let mut stream = session.gate.masker().stream();
        let mut text = String::new();
        for (_, line) in &outcome.output {
            text.push_str(&stream.write(line));
            text.push_str(&stream.write("\n"));
        }
        text.push_str(&stream.finish());
        let truncated = cap(&mut text, max_output);
        let error = outcome.error.map(|e| session.gate.mask(&e));
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

    #[test]
    fn output_caps_on_char_boundaries() {
        let mut text = "héllo".repeat(10);
        assert!(cap(&mut text, 7));
        assert!(text.starts_with("héllo"));
        let mut short = "ok".to_owned();
        assert!(!cap(&mut short, 7));
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
