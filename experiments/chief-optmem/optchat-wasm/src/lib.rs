//! optchat-core as WebAssembly, for the hosted placement (a MemoryDO per
//! agent; plans/cmux-next/optchat.md section 4, decision O1). The JavaScript
//! host keeps messages and node texts in DO SQLite and passes a store object
//! with two methods:
//!
//! - `message(i: number): { kind: string, text: string }`
//! - `node(l: number, i: number): string | undefined`
//!
//! Results that are not plain values come back as JSON text. Ids are JS
//! numbers (exact below 2^53, far beyond any chat).

use optchat_core::{self as core, CompactPrompt, Kind, Memory, NodeId, Store, Work};
use serde::Serialize;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    /// The host's store object.
    pub type JsStore;
    #[wasm_bindgen(method)]
    fn message(this: &JsStore, i: f64) -> JsValue;
    #[wasm_bindgen(method)]
    fn node(this: &JsStore, l: u32, i: f64) -> Option<String>;
}

#[derive(serde::Deserialize)]
struct JsMessage {
    kind: String,
    text: String,
}

/// Adapts the JS store to the core's `Store`.
struct Host<'a>(&'a JsStore);

impl Store for Host<'_> {
    fn message(&self, i: u64) -> (Kind, String) {
        let value = self.0.message(i as f64);
        let m: JsMessage = serde_json::from_str(&js_json(&value)).unwrap_or(JsMessage { kind: "note".into(), text: String::new() });
        (Kind::parse(&m.kind).unwrap_or(Kind::Note), m.text)
    }
    fn node(&self, id: NodeId) -> Option<String> {
        self.0.node(id.l, id.i as f64)
    }
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = JSON, js_name = stringify)]
    fn json_stringify(value: &JsValue) -> String;
}

fn js_json(value: &JsValue) -> String {
    json_stringify(value)
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum WorkJson {
    Free { l: u32, i: u64, text: String },
    Model { l: u32, i: u64 },
}

#[derive(Serialize)]
struct NodeJson {
    l: u32,
    i: u64,
    name: String,
}

/// One agent's memory state in the MemoryDO.
#[wasm_bindgen]
pub struct OptChat {
    memory: Memory,
}

#[wasm_bindgen]
impl OptChat {
    /// A new, empty memory with a view budget in bytes (`VIEW` when 0).
    #[wasm_bindgen(constructor)]
    pub fn new(budget: u32) -> OptChat {
        let budget = if budget == 0 { core::VIEW } else { budget as usize };
        OptChat { memory: Memory::new(budget) }
    }

    /// Rebuilds after a restart: `t` messages and the built nodes as JSON
    /// `[[l, i, bytes], ...]`.
    pub fn load(t: f64, built_json: &str, budget: u32) -> Result<OptChat, JsError> {
        let built: Vec<(u32, u64, usize)> = serde_json::from_str(built_json)?;
        let budget = if budget == 0 { core::VIEW } else { budget as usize };
        Ok(OptChat { memory: Memory::load(t as u64, built.into_iter().map(|(l, i, n)| (NodeId::new(l, i), n)), budget) })
    }

    /// Appends one message (already stored) and returns its id.
    pub fn append(&mut self) -> f64 {
        self.memory.append() as f64
    }

    /// Work to do now, as JSON: `[{kind: "free", l, i, text} | {kind: "model", l, i}]`.
    pub fn pump(&mut self, store: &JsStore) -> String {
        let work: Vec<WorkJson> = self
            .memory
            .pump(&Host(store))
            .into_iter()
            .map(|w| match w {
                Work::Free { node, text } => WorkJson::Free { l: node.l, i: node.i, text },
                Work::Model { node } => WorkJson::Model { l: node.l, i: node.i },
            })
            .collect();
        serde_json::to_string(&work).unwrap_or_else(|_| "[]".into())
    }

    pub fn complete(&mut self, l: u32, i: f64, text: &str) {
        self.memory.complete(NodeId::new(l, i as u64), text);
    }

    pub fn fail(&mut self, l: u32, i: f64) {
        self.memory.fail(NodeId::new(l, i as u64));
    }

    pub fn settled(&self) -> bool {
        self.memory.settled()
    }

    pub fn first(&self) -> f64 {
        self.memory.first() as f64
    }

    pub fn len(&self) -> f64 {
        self.memory.len() as f64
    }

    #[wasm_bindgen(js_name = isEmpty)]
    pub fn is_empty(&self) -> bool {
        self.memory.is_empty()
    }

    #[wasm_bindgen(js_name = viewSize)]
    pub fn view_size(&self) -> f64 {
        self.memory.view_size() as f64
    }

    /// The view parts as JSON `[{l, i, name}]`.
    pub fn view(&self) -> String {
        let parts: Vec<NodeJson> = self.memory.view().iter().map(|p| NodeJson { l: p.l, i: p.i, name: p.name() }).collect();
        serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
    }

    /// The rendered view as JSON `{text, marks}` (marks are byte offsets into the UTF-8 text).
    #[wasm_bindgen(js_name = renderView)]
    pub fn render_view(&self, store: &JsStore) -> String {
        #[derive(Serialize)]
        struct Out {
            text: String,
            marks: Vec<usize>,
        }
        let v = core::render_view(&self.memory, &Host(store));
        serde_json::to_string(&Out { text: v.text, marks: v.marks }).unwrap_or_default()
    }

    /// `zoom(id, n)`; throws "No line id+n." when refused.
    pub fn zoom(&self, store: &JsStore, id: f64, n: f64) -> Result<String, JsError> {
        core::zoom(&self.memory, &Host(store), id as u64, n as u64).map_err(|e| JsError::new(&e.to_string()))
    }

    /// The compactor call for node (l, i) as JSON `{system, context, step}`.
    /// `prompt` is `taelin`, `cmux` or `custom` (then `custom` is its text).
    #[wasm_bindgen(js_name = compactRequest)]
    pub fn compact_request(&self, store: &JsStore, l: u32, i: f64, prompt: &str, custom: &str, agent: &str) -> String {
        #[derive(Serialize)]
        struct Out {
            system: String,
            context: String,
            step: String,
        }
        let choice = match prompt {
            "cmux" => CompactPrompt::Cmux,
            "custom" => CompactPrompt::Custom(custom.to_string()),
            _ => CompactPrompt::Taelin,
        };
        let r = core::compact_request(&self.memory, &Host(store), NodeId::new(l, i as u64), choice.text(agent));
        serde_json::to_string(&Out { system: r.system, context: r.context, step: r.step }).unwrap_or_default()
    }
}

/// The size loop (section 4.3) on the replies so far (JSON array of strings):
/// JSON `{accept: string} | {retry: string} | {fail: true}`.
#[wasm_bindgen(js_name = sizeCheck)]
pub fn size_check(tries_json: &str) -> Result<String, JsError> {
    let tries: Vec<String> = serde_json::from_str(tries_json)?;
    let out = match core::size_check(&tries) {
        core::SizeCheck::Accept(text) => serde_json::json!({ "accept": text }),
        core::SizeCheck::Retry(text) => serde_json::json!({ "retry": text }),
        core::SizeCheck::Fail => serde_json::json!({ "fail": true }),
    };
    Ok(out.to_string())
}
