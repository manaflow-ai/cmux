//! An in-process stand-in for the supervisor (the Rust twin of
//! `js/test/fake-host.ts`): drives an `AppVm`, answers calls from handlers,
//! keeps scene batches and applies them to a reference tree.
#![allow(dead_code)]

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use cmux_app_host::{AppInfo, AppVm, FromHost, InitParams, Limits, VmError};
use serde_json::{Value, json};

pub type Handler = Box<dyn Fn(&Value, &Value) -> (bool, Value)>;

#[derive(Debug, Clone)]
pub struct Call {
    pub cb: u64,
    pub name: String,
    pub params: Value,
    pub options: Value,
}

#[derive(Debug, Clone, Default)]
pub struct Node {
    pub kind: String,
    pub props: serde_json::Map<String, Value>,
    pub children: Vec<String>,
}

pub struct Harness {
    pub vm: AppVm,
    pub scenes: HashMap<String, Vec<Vec<Value>>>,
    pub calls: Vec<Call>,
    pub unanswered: Vec<Call>,
    pub logs: Vec<(String, String)>,
    pub done: HashMap<u64, (bool, Value)>,
    pub subscriptions: BTreeMap<u64, (String, Value)>,
    pub fatal: Option<FromHost>,
    pub handlers: HashMap<String, Handler>,
    /// When false, calls stay in `unanswered` until the test answers them.
    pub auto_answer: bool,
}

pub fn app(body: &str) -> String {
    format!("var __cmuxAppExports = (() => {{ {body} }})();")
}

pub fn sample(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../samples/apps")
        .join(name)
        .join("dist/main.js");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

impl Harness {
    pub fn new(main: &str) -> Self {
        Self::with(
            main,
            json!({ "app": { "id": "local/test", "version": "1.0.0" } }),
            Limits::default(),
        )
    }

    /// `init` may carry `app`, `settings`, `ops`, `knownOps`, `locale`, `strings`.
    pub fn with(main: &str, init: Value, limits: Limits) -> Self {
        let mut vm = AppVm::new(limits).expect("vm");
        let list = |key: &str| -> Option<Vec<String>> {
            init.get(key)
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        };
        let app = init
            .get("app")
            .cloned()
            .unwrap_or_else(|| json!({ "id": "local/test", "version": "1.0.0" }));
        vm.init(InitParams {
            app: AppInfo {
                id: app["id"].as_str().unwrap_or("local/test").into(),
                version: app["version"].as_str().unwrap_or("1.0.0").into(),
            },
            settings: init.get("settings").cloned().unwrap_or_else(|| json!({})),
            api_version: "1.0.0".into(),
            ops: list("ops"),
            known_ops: list("knownOps"),
            locale: init.get("locale").and_then(Value::as_str).map(str::to_string),
            strings: init.get("strings").cloned().unwrap_or(Value::Null),
            main: main.to_string(),
        })
        .expect("init");
        let mut harness = Self {
            vm,
            scenes: HashMap::new(),
            calls: Vec::new(),
            unanswered: Vec::new(),
            logs: Vec::new(),
            done: HashMap::new(),
            subscriptions: BTreeMap::new(),
            fatal: None,
            handlers: HashMap::new(),
            auto_answer: true,
        };
        harness.pump().expect("pump after init");
        harness
    }

    pub fn handle(&mut self, name: &str, f: impl Fn(&Value, &Value) -> (bool, Value) + 'static) {
        self.handlers.insert(name.to_string(), Box::new(f));
    }

    /// Drains the outbox and answers calls until nothing is left.
    pub fn pump(&mut self) -> Result<(), VmError> {
        for _ in 0..64 {
            let outbox = self.vm.take_outbox();
            if outbox.is_empty() {
                return Ok(());
            }
            let mut answers = Vec::new();
            for message in outbox {
                match message {
                    FromHost::Scene { mount, ops } => {
                        self.scenes
                            .entry(mount)
                            .or_default()
                            .push(ops.as_array().cloned().unwrap_or_default());
                    }
                    FromHost::Call { cb, name, params, options } => {
                        let call = Call { cb, name, params, options };
                        self.calls.push(call.clone());
                        if !self.auto_answer {
                            self.unanswered.push(call);
                            continue;
                        }
                        let answer = match self.handlers.get(&call.name) {
                            Some(h) => h(&call.params, &call.options),
                            None => (
                                false,
                                json!({ "code": "operation.unsupported", "message": format!("no handler for {}", call.name), "retryable": false }),
                            ),
                        };
                        answers.push((cb, answer));
                    }
                    FromHost::Log { level, message } => self.logs.push((level, message)),
                    FromHost::Done { cb, ok, body } => {
                        self.done.insert(cb, (ok, body));
                    }
                    FromHost::Subscribe { sub, stream, filter } => {
                        self.subscriptions.insert(sub, (stream, filter));
                    }
                    FromHost::Unsubscribe { sub } => {
                        self.subscriptions.remove(&sub);
                    }
                    fatal @ FromHost::Fatal { .. } => self.fatal = Some(fatal),
                    _ => {}
                }
            }
            for (cb, (ok, body)) in answers {
                self.vm.resolve(cb, ok, &body)?;
            }
        }
        panic!("the app kept calling for 64 rounds");
    }

    pub fn answer(&mut self, cb: u64, ok: bool, body: Value) -> Result<(), VmError> {
        self.unanswered.retain(|c| c.cb != cb);
        self.vm.resolve(cb, ok, &body)?;
        self.pump()
    }

    pub fn mount(&mut self, mount: &str, export: &str, ctx: Value) -> Option<String> {
        let result = self.vm.mount(mount, export, &ctx).expect("mount entry");
        self.pump().expect("pump");
        result
    }

    pub fn dispatch(&mut self, mount: &str, node: &str, event: &str, payload: Value) {
        self.vm.dispatch(mount, node, event, &payload).expect("dispatch");
        self.pump().expect("pump");
    }

    pub fn emit(&mut self, stream: &str, body: Value) {
        let subs: Vec<u64> = self
            .subscriptions
            .iter()
            .filter(|(_, (s, _))| s == stream)
            .map(|(id, _)| *id)
            .collect();
        for sub in subs {
            self.vm.event(sub, &body).expect("event");
        }
        self.pump().expect("pump");
    }

    pub fn eval(&mut self, source: &str) -> Value {
        let value = self.vm.eval_json(source).expect("entry").expect("script");
        self.pump().expect("pump");
        value
    }

    pub fn batches(&self, mount: &str) -> &[Vec<Value>] {
        self.scenes.get(mount).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn tree(&self, mount: &str) -> (String, BTreeMap<String, Node>) {
        let mut nodes: BTreeMap<String, Node> = BTreeMap::new();
        let mut root = String::new();
        for batch in self.batches(mount) {
            for op in batch {
                let id = op["id"].as_str().unwrap_or_default().to_string();
                match op["op"].as_str().unwrap_or_default() {
                    "create" => {
                        nodes.insert(
                            id,
                            Node {
                                kind: op["type"].as_str().unwrap_or_default().into(),
                                props: op["props"].as_object().cloned().unwrap_or_default(),
                                children: vec![],
                            },
                        );
                    }
                    "update" => {
                        let node = nodes.get_mut(&id).expect("update of a known node");
                        for (k, v) in op["props"].as_object().cloned().unwrap_or_default() {
                            if v.is_null() {
                                node.props.remove(&k);
                            } else {
                                node.props.insert(k, v);
                            }
                        }
                    }
                    "children" => {
                        nodes.get_mut(&id).expect("children of a known node").children =
                            op["children"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .filter_map(|c| c.as_str().map(str::to_string))
                                .collect();
                    }
                    "remove" => {
                        nodes.remove(&id);
                    }
                    "root" => root = id,
                    other => panic!("unknown scene op {other}"),
                }
            }
        }
        (root, nodes)
    }

    pub fn texts(&self, mount: &str) -> Vec<String> {
        self.tree(mount)
            .1
            .values()
            .filter_map(|n| {
                n.props
                    .get("title")
                    .or_else(|| n.props.get("text"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .collect()
    }

    pub fn find(&self, mount: &str, pred: impl Fn(&Node) -> bool) -> Option<String> {
        self.tree(mount).1.into_iter().find(|(_, n)| pred(n)).map(|(id, _)| id)
    }
}
