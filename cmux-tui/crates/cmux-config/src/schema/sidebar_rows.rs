//! `sidebar.workspaceRow.lines`, `linesByKind` and `linesByAgent` (CMUX-383): `json` rows whose
//! bounds are the sidebar row reducer's (`cmux_layout_reducer::sidebar_row_layout`). The row's
//! shape checks the nesting and the token names; the reducer then resolves the layout as the app
//! draws it, and every problem it reports (more than three lines, more than six text tokens on a
//! line, the name off the first line, a repeated token) refuses the write. A value already in
//! the file still draws: the reducer skips what it reports. One rule, one place.

use cmux_layout_reducer::sidebar_row_layout::{Request, respond};
use serde_json::{Value, json};

use super::DomainKind;

/// The reducer's problems for `value` written to the row of `domain`, each `{at, why, token?}`
/// (empty when the reducer draws it as written).
pub fn problems(domain: DomainKind, value: &Value) -> Vec<Value> {
    let requests: Vec<Request> = match domain {
        DomainKind::SidebarRowLines => {
            vec![Request { lines: Some(value.clone()), ..Request::default() }]
        }
        DomainKind::SidebarRowLinesByKind | DomainKind::SidebarRowLinesByAgent => {
            let Some(map) = value.as_object() else {
                return vec![json!({"at": key(domain), "why": "notALayout"})];
            };
            // One request per entry, so each entry is resolved as the row it is for. The shape
            // bounds how many entries there are.
            map.keys()
                .map(|name| {
                    let mut request = Request::default();
                    if domain == DomainKind::SidebarRowLinesByKind {
                        request.lines_by_kind = Some(value.clone());
                        request.kind = Some(name.clone());
                    } else {
                        request.lines_by_agent = Some(value.clone());
                        request.agent = Some(name.clone());
                    }
                    request
                })
                .collect()
        }
        _ => return Vec::new(),
    };
    requests
        .iter()
        .flat_map(|request| respond(request).problems)
        .map(|problem| serde_json::to_value(problem).unwrap_or(Value::Null))
        .collect()
}

fn key(domain: DomainKind) -> &'static str {
    use cmux_layout_reducer::sidebar_row_layout::{KEY_BY_AGENT, KEY_BY_KIND, KEY_LINES};
    match domain {
        DomainKind::SidebarRowLinesByKind => KEY_BY_KIND,
        DomainKind::SidebarRowLinesByAgent => KEY_BY_AGENT,
        _ => KEY_LINES,
    }
}

/// The sidebar layout domains.
pub fn is_sidebar_rows(domain: DomainKind) -> bool {
    matches!(
        domain,
        DomainKind::SidebarRowLines
            | DomainKind::SidebarRowLinesByKind
            | DomainKind::SidebarRowLinesByAgent
    )
}
