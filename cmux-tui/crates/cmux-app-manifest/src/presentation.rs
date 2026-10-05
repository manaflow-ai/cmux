//! `presentation` (app-screens.md 4): sidebar item, screen kind, tab, typing
//! target and web-app content. Built-in apps use the same fields.

use crate::issue::Issue;
use serde_json::Value;

/// Sidebar orders below this are first-party only, so no app sits above Home.
pub const FIRST_PARTY_ORDER_LIMIT: i64 = 100;

pub(crate) fn check(m: &Value, first_party: bool, out: &mut Vec<Issue>) {
    let Some(p) = m.get("presentation") else { return };
    if let Some(order) = p.pointer("/sidebarItem/order").and_then(Value::as_i64)
        && order < FIRST_PARTY_ORDER_LIMIT
        && !first_party
    {
        out.push(Issue::error(
            "/presentation/sidebarItem/order",
            "presentation.orderReserved",
            format!("orders below {FIRST_PARTY_ORDER_LIMIT} are reserved for first-party apps"),
        ));
    }
    let page = m.pointer("/implements/cmux.pane~11").is_some();
    let web = p.get("web").is_some();
    let opens = p.get("screen").is_some()
        || p.get("tab").and_then(Value::as_bool) == Some(true)
        || p.get("sidebarItem").is_some();
    if opens && !page && !web {
        out.push(Issue::error(
            "/presentation",
            "presentation.noContent",
            "a sidebar item, screen or tab needs content: implement cmux.pane/1 or give presentation.web",
        ));
    }
    if page && web {
        out.push(Issue::error(
            "/presentation/web",
            "presentation.twoContents",
            "an app shows either its cmux.pane/1 page or a web URL, not both",
        ));
    }
}
