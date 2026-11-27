//! Reads MetricKit's call stack tree JSON: the attributed thread's heaviest path (or, for a
//! per-process tree with no attributed thread, the heaviest root's), innermost frame first.

use serde_json::{Map, Value};

use crate::classify::{is_own_name, is_uuid};
use crate::report::MAX_FRAMES;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawFrame {
    pub binary_name: Option<String>,
    pub binary_uuid: Option<String>,
    pub offset: Option<u64>,
}

type Object = Map<String, Value>;

pub fn stack(json: &[u8]) -> Vec<RawFrame> {
    stack_limited(json, MAX_FRAMES)
}

pub fn stack_limited(json: &[u8], limit: usize) -> Vec<RawFrame> {
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(json) else { return Vec::new() };
    let stacks = objects(root.get("callStacks"));
    if stacks.is_empty() {
        return Vec::new();
    }
    let attributed =
        stacks.iter().copied().find(|stack| attributed_thread(stack.get("threadAttributed")));
    let candidates: Vec<&Object> = match attributed {
        Some(stack) => objects(stack.get("callStackRootFrames")),
        None => stacks.iter().flat_map(|stack| objects(stack.get("callStackRootFrames"))).collect(),
    };
    let mut frame = heaviest(&candidates);
    let mut frames = Vec::new();
    while let Some(current) = frame {
        if frames.len() >= limit {
            break;
        }
        frames.push(RawFrame {
            binary_name: current.get("binaryName").and_then(Value::as_str).map(str::to_owned),
            binary_uuid: current.get("binaryUUID").and_then(Value::as_str).map(str::to_owned),
            offset: unsigned(current.get("offsetIntoBinaryTextSegment")),
        });
        frame = heaviest(&objects(current.get("subFrames")));
    }
    frames
}

/// What the app must look up before building: the stacks' image uuids (uppercased) to find among
/// the loaded images, and their bare names (no folder, not ours) to look for in Apple's folders.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct StackRefs {
    pub names: Vec<String>,
    pub uuids: Vec<String>,
}

pub fn refs<'a, I: IntoIterator<Item = &'a [u8]>>(trees: I) -> StackRefs {
    let mut names = std::collections::BTreeSet::new();
    let mut uuids = std::collections::BTreeSet::new();
    for tree in trees {
        for frame in stack(tree) {
            if let Some(uuid) = frame.binary_uuid.as_deref().filter(|uuid| is_uuid(uuid)) {
                uuids.insert(uuid.to_uppercase());
            }
            if let Some(name) = frame.binary_name.filter(|name| bare_name(name)) {
                names.insert(name);
            }
        }
    }
    StackRefs { names: names.into_iter().collect(), uuids: uuids.into_iter().collect() }
}

/// A name the app checks on disk: non-empty, no folder, not hidden, not one of ours.
pub fn bare_name(name: &str) -> bool {
    !name.is_empty() && !name.contains('/') && !name.starts_with('.') && !is_own_name(name)
}

/// Every element must be an object, as Foundation's `as? [[String: Any]]` cast requires.
fn objects(value: Option<&Value>) -> Vec<&Object> {
    let Some(Value::Array(items)) = value else { return Vec::new() };
    items.iter().map(Value::as_object).collect::<Option<Vec<_>>>().unwrap_or_default()
}

/// The first of the heaviest (a tie keeps the earlier frame).
fn heaviest<'a>(frames: &[&'a Object]) -> Option<&'a Object> {
    let mut best: Option<(&Object, u64)> = None;
    for frame in frames {
        let weight = unsigned(frame.get("sampleCount")).unwrap_or(0);
        if best.is_none_or(|(_, top)| weight > top) {
            best = Some((frame, weight));
        }
    }
    best.map(|(frame, _)| frame)
}

fn attributed_thread(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64() == Some(1.0),
        _ => false,
    }
}

/// A non-negative number under 1.8e19, truncated (a JSON bool reads as 1 or 0, as NSNumber does).
fn unsigned(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::Bool(flag) => Some(u64::from(*flag)),
        Value::Number(number) => {
            if let Some(whole) = number.as_u64() {
                return ((whole as f64) < 1.8e19).then_some(whole);
            }
            let real = number.as_f64()?;
            (0.0..1.8e19).contains(&real).then_some(real as u64)
        }
        _ => None,
    }
}
