//! optchat-core as WebAssembly, for the hosted placement (a MemoryDO per
//! agent; plans/cmux-next/optchat.md section 4, decision O1). The JavaScript
//! host keeps messages and node texts in DO SQLite and passes a store object
//! with two methods:
//!
//! - `message(i: number): { kind: string, text: string }`
//! - `node(l: number, i: number): string | undefined`
//!
//! Results that are not plain values come back as JSON text. Ids are JS
//! numbers (exact below 2^53, far beyond any chat); one that is not a
//! non-negative integer is refused, never cast.
//!
//! A store method that throws, or a message that is not `{kind, text}` with a
//! known kind, is a failed read: the core never builds or starts a node from
//! it (`Store::failed`), and the call throws the read's error to JS with the
//! core state unchanged by it. The next `pump` reads again.

use optchat_core::{self as core, CompactPrompt, Kind, Memory, NodeId, Store, Work};
use serde::Serialize;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    /// The host's store object.
    pub type JsStore;
    #[wasm_bindgen(method, catch)]
    fn message(this: &JsStore, i: f64) -> Result<JsValue, JsValue>;
    #[wasm_bindgen(method, catch)]
    fn node(this: &JsStore, l: u32, i: f64) -> Result<Option<String>, JsValue>;
}

#[derive(serde::Deserialize)]
struct JsMessage {
    kind: String,
    text: String,
}

/// Adapts the JS store to the core's `Store`, keeping the first failed read.
struct Host<'a> {
    store: &'a JsStore,
    error: std::cell::RefCell<Option<String>>,
}

impl<'a> Host<'a> {
    fn new(store: &'a JsStore) -> Host<'a> {
        Host {
            store,
            error: std::cell::RefCell::new(None),
        }
    }

    fn fail(&self, why: String) {
        self.error.borrow_mut().get_or_insert(why);
    }

    /// The first failed read, as the error the call throws.
    fn check(&self) -> Result<(), JsError> {
        match self.error.borrow().as_ref() {
            Some(why) => Err(JsError::new(why)),
            None => Ok(()),
        }
    }
}

fn describe(e: &JsValue) -> String {
    js_string(e)
}

impl Store for Host<'_> {
    fn message(&self, i: u64) -> (Kind, String) {
        let parsed = match self.store.message(i as f64) {
            Ok(value) => serde_json::from_str::<JsMessage>(&js_json(&value))
                .map_err(|e| format!("message {i} is not {{kind, text}}: {e}"))
                .and_then(|m| match Kind::parse(&m.kind) {
                    Some(kind) => Ok((kind, m.text)),
                    None => Err(format!("message {i} has an unknown kind {:?}", m.kind)),
                }),
            Err(e) => Err(format!("reading message {i} failed: {}", describe(&e))),
        };
        parsed.unwrap_or_else(|why| {
            self.fail(why);
            // A stand-in the core never builds from (it checks `failed`).
            (Kind::Note, String::new())
        })
    }
    fn node(&self, id: NodeId) -> Option<String> {
        self.store.node(id.l, id.i as f64).unwrap_or_else(|e| {
            self.fail(format!(
                "reading node {} failed: {}",
                id.name(),
                describe(&e)
            ));
            None
        })
    }
    fn failed(&self) -> bool {
        self.error.borrow().is_some()
    }
}

/// A JS number as an id: a finite, non-negative integer within 2^53.
fn id(x: f64) -> Result<u64, JsError> {
    if x.is_finite() && x >= 0.0 && x.fract() == 0.0 && x <= 9_007_199_254_740_991.0 {
        Ok(x as u64)
    } else {
        Err(JsError::new(&format!(
            "{x} is not a message id (a non-negative integer)"
        )))
    }
}

/// A level: below 64, as every stored node has.
fn level(l: u32) -> Result<u32, JsError> {
    if l < 64 {
        Ok(l)
    } else {
        Err(JsError::new(&format!("{l} is not a tree level")))
    }
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = JSON, js_name = stringify)]
    fn json_stringify(value: &JsValue) -> String;
    /// `String(value)`: an Error shows as "Error: message" (JSON shows `{}`).
    #[wasm_bindgen(js_name = String)]
    fn js_string(value: &JsValue) -> String;
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
        let budget = if budget == 0 {
            core::VIEW
        } else {
            budget as usize
        };
        OptChat {
            memory: Memory::new(budget),
        }
    }

    /// Rebuilds after a restart: `t` messages and the built nodes as JSON
    /// `[[l, i, bytes], ...]`.
    pub fn load(t: f64, built_json: &str, budget: u32) -> Result<OptChat, JsError> {
        let built: Vec<(u32, u64, usize)> = serde_json::from_str(built_json)?;
        if let Some((l, _, _)) = built.iter().find(|(l, _, _)| *l >= 64) {
            return Err(JsError::new(&format!("{l} is not a tree level")));
        }
        let budget = if budget == 0 {
            core::VIEW
        } else {
            budget as usize
        };
        Ok(OptChat {
            memory: Memory::load(
                id(t)?,
                built.into_iter().map(|(l, i, n)| (NodeId::new(l, i), n)),
                budget,
            ),
        })
    }

    /// Appends one message (already stored) and returns its id.
    pub fn append(&mut self) -> f64 {
        self.memory.append() as f64
    }

    /// Work to do now, as JSON: `[{kind: "free", l, i, text} | {kind: "model", l, i}]`.
    /// A failed read stops the pump before it builds anything from it; the
    /// work found before it is returned (the free nodes are built in the core
    /// and must be stored), and with none it throws the read's error.
    pub fn pump(&mut self, store: &JsStore) -> Result<String, JsError> {
        let host = Host::new(store);
        let work = self.memory.pump(&host);
        if work.is_empty() {
            host.check()?;
        }
        let work: Vec<WorkJson> = work
            .into_iter()
            .map(|w| match w {
                Work::Free { node, text } => WorkJson::Free {
                    l: node.l,
                    i: node.i,
                    text,
                },
                Work::Model { node } => WorkJson::Model {
                    l: node.l,
                    i: node.i,
                },
            })
            .collect();
        Ok(serde_json::to_string(&work).unwrap_or_else(|_| "[]".into()))
    }

    pub fn complete(&mut self, l: u32, i: f64, text: &str) -> Result<(), JsError> {
        self.memory.complete(NodeId::new(level(l)?, id(i)?), text);
        Ok(())
    }

    pub fn fail(&mut self, l: u32, i: f64) -> Result<(), JsError> {
        self.memory.fail(NodeId::new(level(l)?, id(i)?));
        Ok(())
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
        let parts: Vec<NodeJson> = self
            .memory
            .view()
            .iter()
            .map(|p| NodeJson {
                l: p.l,
                i: p.i,
                name: p.name(),
            })
            .collect();
        serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
    }

    /// The rendered view as JSON `{text, marks}` (marks are byte offsets into the UTF-8 text).
    #[wasm_bindgen(js_name = renderView)]
    pub fn render_view(&self, store: &JsStore) -> Result<String, JsError> {
        #[derive(Serialize)]
        struct Out {
            text: String,
            marks: Vec<usize>,
        }
        let host = Host::new(store);
        let v = core::render_view(&self.memory, &host);
        host.check()?;
        Ok(serde_json::to_string(&Out {
            text: v.text,
            marks: v.marks,
        })
        .unwrap_or_default())
    }

    /// `zoom(id, n)`; throws "No line id+n." when refused.
    pub fn zoom(&self, store: &JsStore, id: f64, n: f64) -> Result<String, JsError> {
        // A non-integer or negative address names no line (section 7.1).
        let (Ok(i), Ok(count)) = (self::id(id), self::id(n)) else {
            return Err(JsError::new(&format!("No line {id}+{n}.")));
        };
        let host = Host::new(store);
        let out =
            core::zoom(&self.memory, &host, i, count).map_err(|e| JsError::new(&e.to_string()))?;
        host.check()?;
        Ok(out)
    }

    /// The compactor call for node (l, i) as JSON `{system, context, marks, step}`:
    /// `marks` are byte offsets into the UTF-8 context where a cached piece ends
    /// (section 8); send each piece as its own block with a breakpoint.
    /// `prompt` is `taelin`, `cmux` or `custom` (then `custom` is its text).
    #[wasm_bindgen(js_name = compactRequest)]
    pub fn compact_request(
        &self,
        store: &JsStore,
        l: u32,
        i: f64,
        prompt: &str,
        custom: &str,
        agent: &str,
    ) -> Result<String, JsError> {
        #[derive(Serialize)]
        struct Out {
            system: String,
            context: String,
            marks: Vec<usize>,
            step: String,
        }
        let choice = match prompt {
            "cmux" => CompactPrompt::Cmux,
            "custom" => CompactPrompt::Custom(custom.to_string()),
            _ => CompactPrompt::Taelin,
        };
        let host = Host::new(store);
        let r = core::compact_request(
            &self.memory,
            &host,
            NodeId::new(level(l)?, id(i)?),
            choice.text(agent),
        );
        host.check()?;
        let marks = core::cache_marks(&r.context);
        Ok(serde_json::to_string(&Out {
            system: r.system,
            context: r.context,
            marks,
            step: r.step,
        })
        .unwrap_or_default())
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
