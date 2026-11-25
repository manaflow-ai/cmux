//! The daemon supervises this process; QuickJS and every product operation use
//! the same code-mode interpreter, Server::call and catalog as an ordinary chat.
use super::*;
use acpmux::workflow_journal::{Activity, Journal, Stop};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const METHOD: &str = "_acpmux/workflow";
const ACTIVITY_METHOD: &str = "_acpmux/workflow_activity";
const FRESH_CALL_LIMIT: usize = 2_000;

/// JSON object lookup returns null for an absent member without indexing.
fn field<'a>(value: &'a Value, name: &str) -> &'a Value {
    value.get(name).unwrap_or(&Value::Null)
}

/// Installed only around one host-generated call. User-supplied arguments can
/// never construct this value, even when the script guesses an internal action.
pub(super) struct Internal {
    params: Value,
    wait: bool,
}

pub(super) fn internal_call(backend: &impl Backend, operation: Internal) -> Value {
    match backend.acpmux(
        ACTIVITY_METHOD,
        operation.params,
        if operation.wait { Duration::from_secs(24 * 3600) } else { Duration::from_secs(60) },
        None,
        !operation.wait,
    ) {
        // This bridge is internal to the interpreter, not an MCP response to
        // a model. Keep the complete outcome for durable journal delivery.
        Ok(value) => json!({"isError":false,"content":[],"structuredContent":value}),
        Err(error) => failure_result(error),
    }
}

struct Proof {
    run_id: String,
    generation: u64,
    token: String,
}

impl Proof {
    fn params(&self, action: &str) -> Value {
        json!({"action":action,"runId":self.run_id,"generation":self.generation,
            "runnerToken":self.token})
    }

    fn request(&self, backend: &impl Backend, action: &str) -> Result<Value, String> {
        backend.acpmux(METHOD, self.params(action), Duration::from_secs(60), None, false).map_err(
            |error| {
                field(&error.error, "message")
                    .as_str()
                    .unwrap_or("workflow owner unavailable")
                    .to_owned()
            },
        )
    }
}

/// Called only by the hidden daemon launch command. A fresh, launch-local
/// proof and the normal caller proof are both checked by acpmux before source
/// or a journal path is returned. Neither credential is stored in the journal.
pub(super) fn run(global: GlobalArgs, run_id: String, generation: u64) -> i32 {
    let execute = || -> Result<(), String> {
        let token = std::env::var(acpmux::workflow_runs::RUNNER_TOKEN_ENV)
            .map_err(|_| "workflow runner needs a daemon launch proof".to_owned())?;
        let proof = Proof { run_id, generation, token };
        let path = config::path();
        if let Some(message) = refusal(&path) {
            return Err(message);
        }
        let mut server = Server::new(LiveBackend { global }, Some(path));
        let claim = proof.request(&server.backend, "claim")?;
        let source = field(&claim, "source").as_str().ok_or("workflow claim omitted source")?;
        let directory =
            field(&claim, "journalDir").as_str().ok_or("workflow claim omitted journal")?;
        // The daemon computes the intersection of the pinned ceiling and the
        // owner's current trusted tool profile. No script option widens it.
        refresh_tools(&mut server, &claim)?;
        server.upstreams = upstream::specs(std::env::var_os(upstream::ENV))
            .into_iter()
            .map(|spec| upstream::Proxied::new(upstream::Upstream::new(spec)))
            .collect();
        let mut journal = Journal::open_handoff(
            std::path::Path::new(directory),
            source,
            FRESH_CALL_LIMIT,
            Duration::from_secs(60),
        )
        .map_err(|error| error.to_string())?;
        proof.request(&server.backend, "check")?;
        let mut pending = BTreeMap::new();
        let mut tools = None;
        let mut images = Vec::new();
        let mut fatal: Option<String> = None;
        let outcome = code_mode::workflow_exec(
            source,
            field(&claim, "args").clone(),
            server.script_limits,
            &mut |request| {
                if let Some(message) = &fatal {
                    return refused("workflow.host", message);
                }
                let answer = handle(
                    &mut server,
                    &proof,
                    &mut journal,
                    &mut pending,
                    &mut tools,
                    &mut images,
                    request,
                );
                match answer {
                    Ok(value) => value,
                    Err(message) => {
                        fatal = Some(message.clone());
                        refused("workflow.host", &message)
                    }
                }
            },
        );
        if journal.stop_reason() == Some(Stop::CallBudget) {
            // This RPC fences and terminates this process. A disconnect is
            // expected; never overwrite the paused state with a failure.
            let _ = proof.request(&server.backend, "suspend");
            return Ok(());
        }
        let outcome = match (fatal, outcome) {
            (Some(message), _) => Err(json!({"code":"workflow.host","message":message})),
            (_, Err(message)) => Err(json!({"code":"workflow.engine","message":message})),
            (_, Ok(answer)) if field(&answer, "isError").as_bool() == Some(true) => {
                Err(field(&answer, "structuredContent").clone())
            }
            (_, Ok(answer)) => match journal.finish() {
                Ok(()) => Ok(field(&answer, "structuredContent").clone()),
                Err(error) => Err(json!({"code":"workflow.journal","message":error.to_string()})),
            },
        };
        let mut params = proof.params("settle");
        params.set("outcome", serde_json::to_value(outcome).map_err(|error| error.to_string())?);
        server.backend.acpmux(METHOD, params, Duration::from_secs(60), None, true).map_err(
            |error| {
                field(&error.error, "message")
                    .as_str()
                    .unwrap_or("cannot settle workflow")
                    .to_owned()
            },
        )?;
        Ok(())
    };
    match execute() {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("cmux workflow: {message}");
            1
        }
    }
}

fn refresh_tools<B: Backend>(server: &mut Server<B>, check: &Value) -> Result<(), String> {
    server.allowed = match check.get("allowedTools") {
        Some(Value::Null) => None,
        Some(value) => Some(
            serde_json::from_value::<BTreeSet<String>>(value.clone())
                .map_err(|_| "workflow check has an invalid tool ceiling")?,
        ),
        None => return Err("workflow check omitted tool ceiling".into()),
    };
    if let Some(names) = check.get("upstreamNames") {
        let names: BTreeSet<String> = serde_json::from_value(names.clone())
            .map_err(|_| "workflow check has invalid upstream names")?;
        server.upstreams.retain(|upstream| names.contains(&upstream.name));
    }
    Ok(())
}

type Pending = BTreeMap<String, Option<Result<Value, Value>>>;

fn handle<B: Backend>(
    server: &mut Server<B>,
    proof: &Proof,
    journal: &mut Journal,
    pending: &mut Pending,
    tools: &mut Option<Vec<Value>>,
    images: &mut Vec<Value>,
    request: code_mode::Request,
) -> Result<Value, String> {
    // Even replay and raw cmux.call are fenced before they can advance the
    // interpreter. A paused/replaced runner cannot dispatch another mutation.
    let check = proof.request(&server.backend, "check")?;
    let previous = server.allowed.clone();
    let upstreams = server.upstreams.len();
    refresh_tools(server, &check)?;
    if previous != server.allowed || upstreams != server.upstreams.len() {
        *tools = None;
    }
    if let Some(refusal) = server.tool_refusal("cmux_workflow") {
        return Ok(code_mode::script_answer(Ok(refusal), images));
    }
    match request {
        code_mode::Request::ActivityStart { kind, prompt, options } => {
            let required = match kind.as_str() {
                "agent" => "agent_dispatch",
                "machine" => "acpmux_bg_start",
                _ => return Ok(refused("workflow.kind", "unknown workflow primitive")),
            };
            if server.allowed.as_ref().is_some_and(|allowed| !allowed.contains(required)) {
                return Ok(refused(
                    "tool.not_allowed",
                    &format!("this chat may not use {required}"),
                ));
            }
            let activity = match journal.begin(&kind, &prompt, &Value::Object(options.clone())) {
                Ok(activity) => activity,
                Err(error) => return Ok(refused("workflow.journal", &error.to_string())),
            };
            let id = journal.last_id().ok_or("journal omitted reserved identity")?.to_owned();
            match activity {
                Activity::Replay(result) => {
                    pending.insert(id.clone(), Some(result));
                }
                Activity::Work { .. } => {
                    let mut params = proof.params("start");
                    params.set("activityId", json!(transport_id(&id)));
                    params.set("kind", json!(kind));
                    params.set("prompt", json!(prompt));
                    params.set("options", json!(options));
                    let answer = internal(server, params, false, images);
                    if field(&answer, "ok").as_bool() != Some(true) {
                        return Ok(answer);
                    }
                    pending.insert(id.clone(), None);
                }
            }
            Ok(json!({"ok":true,"value":{"id":id}}))
        }
        code_mode::Request::ActivityWait { ids } => {
            if ids.is_empty() || ids.iter().any(|id| !pending.contains_key(id)) {
                return Err("workflow wait named an unknown activity".into());
            }
            if let Some(id) = journal.next_replay(&ids) {
                let result = pending.remove(&id).flatten().ok_or("replay outcome missing")?;
                return Ok(json!({"ok":true,"value":{"id":id,"outcome":result}}));
            }
            let mut params = proof.params("wait");
            let mapped =
                ids.iter().map(|id| (transport_id(id), id.clone())).collect::<BTreeMap<_, _>>();
            params.set("activityIds", json!(mapped.keys().collect::<Vec<_>>()));
            let answer = internal(server, params, true, images);
            if field(&answer, "ok").as_bool() != Some(true) {
                return Ok(answer);
            }
            let selected = field(field(&answer, "value"), "activityId")
                .as_str()
                .ok_or("wait omitted activity identity")?;
            let id = mapped.get(selected).ok_or("wait returned an unrelated activity")?;
            let result: Result<Value, Value> =
                serde_json::from_value(field(field(&answer, "value"), "outcome").clone())
                    .map_err(|error| format!("wait returned invalid outcome: {error}"))?;
            journal.complete(id, result.clone()).map_err(|error| error.to_string())?;
            pending.remove(id);
            Ok(json!({"ok":true,"value":{"id":id,"outcome":result}}))
        }
        request => {
            let (name, arguments) = match &request {
                code_mode::Request::Call { name, arguments } => {
                    if let Some(refusal) = server.tool_refusal(name) {
                        return Ok(code_mode::script_answer(Ok(refusal), images));
                    }
                    // A tool's provider can be revoked without narrowing the
                    // name allowlist. Replay must obey the current catalog too.
                    if name != code_mode::DOCS
                        && name != code_mode::EXEC
                        && !tools
                            .get_or_insert_with(|| server.list())
                            .iter()
                            .any(|tool| field(tool, "name").as_str() == Some(name.as_str()))
                    {
                        return Ok(refused(
                            "tool.unavailable",
                            &format!("{name} is outside the current tool catalog"),
                        ));
                    }
                    (name.as_str(), json!(arguments))
                }
                code_mode::Request::Docs { query } => ("cmux.docs", json!({"query":query})),
                _ => return Err("unexpected workflow host request".into()),
            };
            match journal.begin("call", name, &arguments).map_err(|error| error.to_string())? {
                Activity::Replay(Ok(answer)) => Ok(answer),
                Activity::Replay(Err(error)) => Ok(refused("workflow.call", &error.to_string())),
                Activity::Work { recovered: true, .. } => Err(
                    "an interrupted raw tool call has an uncertain outcome; inspect its effect before starting a new run".into()),
                Activity::Work { id, recovered: false } => {
                    let answer = server.script_request(request, tools, images);
                    journal.complete(&id, Ok(answer.clone())).map_err(|error| error.to_string())?;
                    Ok(answer)
                }
            }
        }
    }
}

fn internal<B: Backend>(
    server: &mut Server<B>,
    params: Value,
    wait: bool,
    images: &mut Vec<Value>,
) -> Value {
    server.workflow_activity = Some(Internal { params, wait });
    let result = server.call(&json!({"name":"cmux_workflow","arguments":{}}));
    server.workflow_activity = None;
    code_mode::script_answer(result, images)
}

fn transport_id(id: &str) -> String {
    format!("{:x}", Sha256::digest(id.as_bytes()))
}

fn refused(code: &str, message: &str) -> Value {
    json!({"ok":false,"message":message,"error":{"code":code,"message":message}})
}

#[cfg(test)]
mod tests;
