//! The Tasks entries of the operation catalog (spec/operation-catalog.md).
//!
//! One list (`entries::all`) drives every surface: the CLI parser (flags
//! come from params), the MCP tool list, the mux code-mode TypeScript
//! declarations, palette actions in the app (from the exported JSON) and the
//! merged catalog file. Nothing else declares a Tasks op.

mod entries;

use serde_json::{Map, Value, json};

pub use entries::all;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Read,
    Mutation,
    Stream,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Risk {
    Read,
    MutateOwn,
    MutateShared,
    Execute,
    Destructive,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Expose {
    Default,
    OptIn,
    Never,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ty {
    Str,
    /// A public id with this prefix; `generate` makes the CLI mint one when omitted.
    Id {
        prefix: &'static str,
        generate: bool,
    },
    /// A task reference: `CMX-12`, `task_…` or a unique id prefix.
    TaskRef,
    Bool,
    U32,
    U64,
    I64,
    Enum(&'static [&'static str]),
    /// Structured JSON (plan steps); the CLI reads it from a file (`@path`) or inline.
    Json,
}

#[derive(Clone, Copy, Debug)]
pub struct Param {
    pub name: &'static str,
    pub ty: Ty,
    pub required: bool,
    /// The CLI takes it as the first positional argument.
    pub positional: bool,
    /// An array of `ty`; the CLI flag may repeat.
    pub repeated: bool,
    pub doc: &'static str,
}

#[derive(Clone, Copy, Debug)]
pub struct Entry {
    pub name: &'static str,
    pub class: Class,
    pub risk: Risk,
    /// CLI path under the `cmux` binary, e.g. `task comment add`.
    pub cli: &'static str,
    pub mcp: Expose,
    /// Command palette title (English; the app localizes by op name).
    pub palette: Option<&'static str>,
    pub docs: &'static str,
    pub params: &'static [Param],
}

pub const OWNER: &str = "tasks";

impl Entry {
    pub fn idempotency(&self) -> &'static str {
        match self.class {
            Class::Mutation => "required",
            Class::Read | Class::Stream => "forbidden",
        }
    }

    /// JSON Schema (2020-12 subset) of the params.
    pub fn input_schema(&self) -> Value {
        let mut properties = Map::new();
        let mut required = Vec::new();
        for p in self.params {
            let item = ty_schema(p.ty, p.doc);
            let schema = if p.repeated {
                json!({"type": "array", "items": item, "description": p.doc})
            } else {
                item
            };
            properties.insert(p.name.to_owned(), schema);
            if p.required {
                required.push(Value::from(p.name));
            }
        }
        json!({"type": "object", "properties": properties, "required": required, "additionalProperties": false})
    }

    /// One entry in the merged catalog format.
    pub fn to_catalog_json(&self) -> Value {
        json!({
            "name": self.name,
            "owner": OWNER,
            "class": match self.class { Class::Read => "read", Class::Mutation => "mutation", Class::Stream => "stream" },
            "risk": match self.risk {
                Risk::Read => "read", Risk::MutateOwn => "mutate-own", Risk::MutateShared => "mutate-shared",
                Risk::Execute => "execute", Risk::Destructive => "destructive",
            },
            "idempotency": self.idempotency(),
            "focuses": false,
            "queue_offline": false,
            "remote_relay": "deny",
            "input": self.input_schema(),
            "cli": {"path": self.cli, "visible": true},
            "mcp": {"expose": match self.mcp { Expose::Default => "default", Expose::OptIn => "opt_in", Expose::Never => "never" }, "group": "task"},
            "palette": self.palette.map(|title| json!({"title": title})),
            "code_mode": {"path": format!("mux.{}", self.name)},
            "since": "tasks/1",
            "docs": self.docs,
        })
    }

    /// MCP tool name: dots become underscores.
    pub fn mcp_name(&self) -> String {
        self.name.replace('.', "_")
    }
}

fn ty_schema(ty: Ty, doc: &str) -> Value {
    match ty {
        Ty::Str => json!({"type": "string", "description": doc}),
        Ty::Id { prefix, .. } => {
            json!({"type": "string", "pattern": format!("^{prefix}[0-9a-z_-]{{1,64}}$"), "description": doc})
        }
        Ty::TaskRef => json!({"type": "string", "description": doc}),
        Ty::Bool => json!({"type": "boolean", "description": doc}),
        Ty::U32 | Ty::U64 => json!({"type": "integer", "minimum": 0, "description": doc}),
        Ty::I64 => json!({"type": "integer", "description": doc}),
        Ty::Enum(values) => json!({"type": "string", "enum": values, "description": doc}),
        Ty::Json => json!({"description": doc}),
    }
}

pub fn find(name: &str) -> Option<&'static Entry> {
    all().iter().find(|e| e.name == name)
}

pub fn find_cli(words: &[&str]) -> Option<(&'static Entry, usize)> {
    // Longest CLI path that prefixes `words`.
    all()
        .iter()
        .filter_map(|e| {
            let path: Vec<&str> = e.cli.split(' ').collect();
            (words.len() >= path.len() && words[..path.len()] == path[..])
                .then_some((e, path.len()))
        })
        .max_by_key(|(_, n)| *n)
}

/// The merged-catalog export (`cmux-tasks catalog`).
pub fn export_json() -> Value {
    json!({
        "schema_version": 1,
        "owner": OWNER,
        "family": "task",
        "operations": all().iter().map(Entry::to_catalog_json).collect::<Vec<_>>(),
        "trigger_events": crate::event::TRIGGER_EVENTS,
    })
}

/// MCP tool definitions; `include_opt_in` adds the opt-in group.
pub fn mcp_tools(include_opt_in: bool) -> Value {
    let tools: Vec<Value> = all()
        .iter()
        .filter(|e| e.mcp == Expose::Default || (include_opt_in && e.mcp == Expose::OptIn))
        .map(|e| json!({"name": e.mcp_name(), "description": e.docs, "inputSchema": e.input_schema()}))
        .collect();
    Value::Array(tools)
}

fn ts_type(ty: Ty) -> String {
    match ty {
        Ty::Str | Ty::Id { .. } | Ty::TaskRef => "string".to_owned(),
        Ty::Bool => "boolean".to_owned(),
        Ty::U32 | Ty::U64 | Ty::I64 => "number".to_owned(),
        Ty::Enum(values) => {
            values.iter().map(|v| format!("\"{v}\"")).collect::<Vec<_>>().join(" | ")
        }
        Ty::Json => "unknown".to_owned(),
    }
}

/// Mux code-mode declarations: `mux.task.create(params)` and friends.
pub fn export_typescript() -> String {
    let mut out = String::from("// Generated from cmux-tasks-core::catalog. Do not edit.\n");
    let mut functions = String::new();
    for e in all() {
        let name = upper_camel(e.name);
        out.push_str(&format!("/** {} */\nexport interface {name}Params {{\n", e.docs));
        for p in e.params {
            let ty = ts_type(p.ty);
            let ty = if p.repeated { format!("Array<{ty}>") } else { ty };
            let optional = if p.required { "" } else { "?" };
            out.push_str(&format!("  /** {} */\n  {}{optional}: {ty};\n", p.doc, p.name));
        }
        out.push_str("}\n");
        let result = match e.class {
            Class::Mutation => "OpResult",
            Class::Read => "unknown",
            Class::Stream => "AsyncIterable<TaskEvent>",
        };
        let member = e.name.trim_start_matches("task.").replace('.', "_");
        functions.push_str(&format!(
            "    /** {} */\n    {member}(params: {name}Params): Promise<{result}>;\n",
            e.docs
        ));
    }
    out.push_str("export interface OpResult { id: string; key?: string }\nexport interface TaskEvent { seq: number; index: number; tx: string; kind: string; details?: unknown; change: unknown }\n");
    out.push_str(&format!("export interface Mux {{\n  task: {{\n{functions}  }};\n}}\n"));
    out
}

fn upper_camel(path: &str) -> String {
    path.split(['_', '.'])
        .filter(|s| !s.is_empty())
        .map(|s| s[..1].to_uppercase() + &s[1..])
        .collect()
}
