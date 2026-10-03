//! The shared behavior corpus, format `cmux-chief-corpus/1`
//! (plans/cmux-next/chief-mac.md section 4). Each case starts a core from a
//! durable state, feeds inputs with their time, and expects the exact
//! effects (`log` effects are not compared: their text is diagnostics) and
//! the durable state after. Expected effects and states stay JSON values and
//! are compared with `serde_json::to_value` of the result, so a missing,
//! extra or unknown field fails. Memory cases call one pure memory function.
//! The TypeScript core runs the same file, so both brains stay equal.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::core::{Core, Effect, Input};
use crate::memory::{self, ArrayMemoryStore, Range};
use crate::state::HostState;

pub const FORMAT: &str = "cmux-chief-corpus/1";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Corpus {
    pub format: String,
    #[serde(default)]
    pub cases: Vec<Case>,
    #[serde(default)]
    pub memory: Vec<MemoryCase>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Case {
    pub name: String,
    #[serde(default)]
    pub state: HostState,
    pub steps: Vec<Step>,
    pub state_after: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Step {
    /// Milliseconds since the epoch.
    pub now: u64,
    pub input: Input,
    pub effects: Vec<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryCase {
    pub name: String,
    /// `to_lines`, `decompose`, `wake_cover`, `wake` or `zoom`.
    #[serde(rename = "fn")]
    pub function: String,
    pub args: Value,
    pub result: Value,
}

/// Runs one case; the error names the first step that differs.
pub fn run_case(case: &Case) -> Result<(), String> {
    let mut core = Core::new(case.state.clone());
    let log = json!("log");
    for (index, step) in case.steps.iter().enumerate() {
        let got: Vec<Effect> = core
            .step(step.input.clone(), step.now)
            .into_iter()
            .filter(|effect| !matches!(effect, Effect::Log { .. }))
            .collect();
        let got_json = serde_json::to_value(&got).map_err(|e| e.to_string())?;
        let want_json = Value::Array(
            step.effects
                .iter()
                .filter(|effect| effect.get("kind") != Some(&log))
                .cloned()
                .collect(),
        );
        if got_json != want_json {
            return Err(format!(
                "{}: step {index}: effects differ\n  want {want_json}\n  got  {got_json}",
                case.name
            ));
        }
    }
    let got = serde_json::to_value(&core.state).map_err(|e| e.to_string())?;
    if got != case.state_after {
        let want = &case.state_after;
        return Err(format!("{}: state_after differs\n  want {want}\n  got  {got}", case.name));
    }
    Ok(())
}

/// Runs one memory case.
pub fn run_memory_case(case: &MemoryCase) -> Result<(), String> {
    let got = memory_result(&case.function, &case.args)
        .map_err(|error| format!("{}: {error}", case.name))?;
    if got != case.result {
        return Err(format!("{}: want {} got {got}", case.name, case.result));
    }
    Ok(())
}

fn memory_result(function: &str, args: &Value) -> Result<Value, String> {
    let number = |key: &str| args.get(key).and_then(Value::as_u64).ok_or(format!("missing {key}"));
    let ranges = |list: Vec<Range>| json!(list.iter().map(|r| r.key()).collect::<Vec<_>>());
    let store = || -> Result<ArrayMemoryStore, String> {
        let lines = args.get("lines").cloned().unwrap_or_else(|| json!([]));
        let nodes = args.get("nodes").cloned().unwrap_or_else(|| json!({}));
        let lines: Vec<String> = serde_json::from_value(lines).map_err(|e| e.to_string())?;
        let nodes: std::collections::BTreeMap<String, String> =
            serde_json::from_value(nodes).map_err(|e| e.to_string())?;
        let mut store = ArrayMemoryStore { lines, ..Default::default() };
        for (key, summary) in nodes {
            let range = Range::parse(&key).ok_or(format!("bad node key {key}"))?;
            store.nodes.insert(range, summary);
        }
        Ok(store)
    };
    Ok(match function {
        "to_lines" => {
            let text = args.get("text").and_then(Value::as_str).ok_or("missing text")?;
            json!(memory::to_lines(text))
        }
        "decompose" => ranges(memory::decompose(number("length")?)),
        "wake_cover" => ranges(memory::wake_cover(number("length")?, number("budget")? as usize)),
        "wake" => {
            let view = memory::wake(&store()?, number("budget")? as usize);
            json!({"text": view.text, "missing": ranges(view.missing)})
        }
        "zoom" => {
            let range = args.get("range").and_then(Value::as_str).and_then(Range::parse);
            json!(memory::zoom(&store()?, range.ok_or("missing range")?))
        }
        other => return Err(format!("unknown memory function {other}")),
    })
}

/// Runs a whole corpus; returns every failure.
pub fn run(corpus: &Corpus) -> Vec<String> {
    let mut failures = Vec::new();
    if corpus.format != FORMAT {
        failures.push(format!("format {} is not {FORMAT}", corpus.format));
        return failures;
    }
    failures.extend(corpus.cases.iter().filter_map(|case| run_case(case).err()));
    failures.extend(corpus.memory.iter().filter_map(|case| run_memory_case(case).err()));
    failures
}
