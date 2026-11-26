//! Catalog requests: an action that runs as one daemon request named in its catalog row
//! (`Action::request`), and suggestion sources answered by one list request
//! (`op:<operation>`). The app binds both once (`CatalogRequestHandlers`), with no handler or
//! source per action.

use crate::model::*;
use serde_json::{Map, Value};

/// The list requests `op:` suggestion sources name.
pub static LIST_SOURCES: &[ListSource] = &[
    ListSource {
        lane: RequestLane::Session,
        operation: "closed.list",
        items: None,
        value: "id",
        title: "name",
    },
    // acpmux's ACP session list (its first page, newest first): the sessions `agent open` and
    // `agent open-tab` take by id. A row with no title shows its id.
    ListSource {
        lane: RequestLane::Acpmux,
        operation: "session/list",
        items: Some("sessions"),
        value: "sessionId",
        title: "title",
    },
    // The session's terminals (`cmux terminal list`, every one with or without a tab), by
    // title: the terminal Show Terminal in New Tab puts in a tab.
    ListSource {
        lane: RequestLane::Session,
        operation: "terminal.list",
        items: None,
        value: "id",
        title: "title",
    },
];

/// The list request a suggestion `source` names (`op:closed.list`), if it is one.
pub fn list_source(source: &str) -> Option<&'static ListSource> {
    let operation = source.strip_prefix(LIST_SOURCE_PREFIX)?;
    LIST_SOURCES.iter().find(|list| list.operation == operation)
}

/// A constant param's JSON value.
pub fn constant(value: &BindingValue) -> Value {
    match value {
        BindingValue::String(s) => Value::String((*s).to_owned()),
        BindingValue::Int(i) => Value::from(*i),
        BindingValue::Bool(b) => Value::Bool(*b),
    }
}

/// The params `request` sends, given the value of each argument and target source
/// (`value`, which answers `None` for an omitted argument or a missing target). The app fills
/// the routing defaults (`machine`, `session`) on the session lane, as the CLI does.
pub fn params(
    request: &Request,
    value: impl Fn(&ParamSource) -> Option<Value>,
) -> Map<String, Value> {
    let mut params = Map::new();
    for param in request.params {
        let resolved = match &param.source {
            ParamSource::Constant(constant_value) => Some(constant(constant_value)),
            source => value(source),
        };
        if let Some(resolved) = resolved {
            params.insert(param.name.to_owned(), resolved);
        }
    }
    params
}
