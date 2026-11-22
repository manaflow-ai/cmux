//! `frame.observe`: the structured read of a frame (automation lease
//! `observe`).
//!
//! An agent's reads (snapshots, locator resolution and polls, waits) used to
//! go through `frame.evaluate`, which can run any code and so counts as an
//! act: a second session could not snapshot a held tab, and the re-snapshot
//! after a person's hand back failed. `frame.observe {method, args}` calls one
//! read-only page agent function from a fixed allowlist. The host writes the
//! script; the caller sends only the function name and JSON arguments. Every
//! engine runs it as the matching agent-world `frame.evaluate`, after the
//! lease check counted it as an observe.
//!
//! Observe works on a tab another session holds, so its results never carry a
//! sensitive field's value: a password, one-time code, or card field reads as
//! [`FIELD_MARKER`] (browser-host.md, frame.observe).

use crate::protocol::{DriverError, ErrorCode};
use serde_json::{Value, json};

/// The page agent functions `frame.observe` may call. They read the DOM and
/// the agent's own tables, and change nothing the page can see.
pub const OBSERVE_AGENT_METHODS: &[&str] = &[
    "ping",
    "snapshot",
    "stats",
    "refState",
    "refForHandle",
    "elementAt",
    "splitFrames",
    "queryAll",
    "describe",
    "strictError",
    "elementState",
    "checkStates",
    "rect",
    "contentBox",
    "iframeHandles",
    "retarget",
    "read",
    "activeHandle",
];

/// What a sensitive field's value reads as.
pub const FIELD_MARKER: &str = "********";

/// The `errorName` of a call to a function that is not in the allowlist.
pub const NOT_ALLOWED: &str = "observe_not_allowed";

const MAX_ARGS: usize = 8;
/// Larger numbers are refused: a huge ref base would stop the page agent's
/// ref counter for the session that holds the tab.
const MAX_NUMBER: f64 = 1_000_000_000.0;

/// Functions whose string arguments are selectors.
const SELECTOR_METHODS: &[&str] = &["queryAll", "strictError", "splitFrames"];

/// A selector that tests the `value` attribute (`[value^=...]`, also inside
/// `internal:attr=`) can read a field value one character at a time, so
/// observe refuses it. Other attribute tests (`role=button[name="x"]`,
/// `[data-test=a]`) stay allowed.
fn tests_a_value(selector: &str) -> bool {
    let text = decode_css_escapes(selector).to_lowercase();
    if text.contains("@value") {
        return true; // XPath: //input[@value="a"], starts-with(@value, "a")
    }
    text.match_indices("value").any(|(at, _)| {
        // `[value^=`, `[*|value^=`, `[ns|value=`: the name ends the word.
        let before = text[..at].chars().next_back();
        let name_start = matches!(before, Some('[' | '|' | ' ' | '\t'));
        let rest = text[at + "value".len()..].trim_start();
        name_start && matches!(rest.chars().next(), Some('=' | '^' | '$' | '*' | '~' | '|'))
    })
}

/// Decodes CSS escapes (`\76 alue` is `value`) so they cannot hide a name.
fn decode_css_escapes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        let mut hex = String::new();
        while hex.len() < 6 && chars.peek().is_some_and(char::is_ascii_hexdigit) {
            hex.extend(chars.next());
        }
        if hex.is_empty() {
            out.extend(chars.next());
        } else {
            if chars.peek().is_some_and(|c| c.is_whitespace()) {
                chars.next();
            }
            out.extend(u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32));
        }
    }
    out
}

/// Every string inside the arguments (nested arrays and objects included).
fn any_string(value: &Value, test: &dyn Fn(&str) -> bool) -> bool {
    match value {
        Value::String(text) => test(text),
        Value::Array(items) => items.iter().any(|item| any_string(item, test)),
        Value::Object(map) => map.values().any(|item| any_string(item, test)),
        _ => false,
    }
}

fn numbers_in_range(value: &Value) -> bool {
    match value {
        Value::Number(n) => n.as_f64().is_some_and(|n| n.is_finite() && n.abs() <= MAX_NUMBER),
        Value::Array(items) => items.iter().all(numbers_in_range),
        Value::Object(map) => map.values().all(numbers_in_range),
        _ => true,
    }
}
const MAX_ARGS_BYTES: usize = 64 * 1024;

/// The host-written agent-world script. It runs one allowlisted function and
/// hides the values of sensitive fields (type=password; autocomplete
/// one-time-code, current-password, new-password or cc-*): a direct read of
/// such a field gives the marker, and the text results (snapshot, read,
/// describe, strictError) have every such value replaced by the marker
/// (substring for values of 4+ characters, whole string otherwise). The scan
/// for those values reads within the page-read budget; when the budget stops
/// it, the read is refused with the read-cut marker.
const OBSERVE_SOURCE: &str = r#"async (m, ...a) => {
  const A = globalThis[Symbol.for("cmux.browserRepl.agent")];
  const MARK = "********";
  const sensitive = (el) => {
    if (!el || String(el.tagName || "").toLowerCase() !== "input") return false;
    if (String(el.type || "").toLowerCase() === "password") return true;
    return String(el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/)
      .some((t) => t === "one-time-code" || t === "current-password" || t === "new-password" || t.startsWith("cc-"));
  };
  if (m === "read" && (a[1] === "inputValue" || (a[1] === "getAttribute" && String(a[2]).toLowerCase() === "value"))) {
    let el = A.element(a[0]);
    if (a[1] === "inputValue") {
      const target = A.retarget(a[0], "follow-label");
      if (target !== null && target !== undefined) el = A.element(target);
    }
    if (sensitive(el)) {
      const v = a[1] === "inputValue" ? el.value : el.getAttribute("value");
      return v ? MARK : v;
    }
  }
  // The read runs inside the agent's reply, which settles the cuts it made
  // before the values are scrubbed (a cut never ends inside a value).
  const value = await A.reply(A[m](...a));
  if (!["snapshot", "read", "describe", "strictError"].includes(m)) return value;
  if (value && typeof value === "object" && value.__cmuxReplyCut) return value;
  // The scan reads within the page-read budget (one node per element, the
  // values' characters and a scoped read's attribute text as size). A
  // scoped read (snapshot of a root, read or describe of an element,
  // strictError of its elements) scans its part first: its subtrees, and,
  // until none is left, every element they name by id in any attribute
  // (aria-labelledby, for, aria-owns, ...), their labels and the nodes
  // slotted into them, because a name or text can come from those. Then the
  // rest of the frame, with what the budget has left. When the budget stops
  // the scan of the scoped part, or of the whole frame for an unscoped
  // read, the read is refused with the cut marker (the runtime prints
  // core.readCutNote, with a hint to scope an unscoped read); a scoped read
  // whose part was scanned whole is scrubbed of that part's values. A
  // partial scrub of the part a read shows is never returned.
  // Iterative over shadow roots: a page can nest them deeper than the stack.
  const B = A.budget({});
  const scope = m === "snapshot" ? (a[0] && a[0].root ? [A.element(a[0].root)] : null)
    : m === "strictError" ? (Array.isArray(a[1]) ? a[1].map((h) => A.element(h)) : null)
    : [A.element(a[0])];
  // inputValue reads the control a label names (follow-label), which can
  // be outside the label's subtree: that control is in the part too.
  if (m === "read" && a[1] === "inputValue") {
    const target = A.retarget(a[0], "follow-label");
    if (target !== null && target !== undefined) scope.push(A.element(target));
  }
  const cut = (part) => {
    const r = B.report();
    return { __cmuxReplyCut: { truncated: r.truncated, maxNodes: r.maxNodes, maxSize: r.maxSize, scope: part } };
  };
  const secrets = [];
  // Scans `roots` (elements, the document, shadow roots) and every shadow
  // root inside; false when the budget stopped it. `follow` (the scoped
  // part): also queue what each element names, and skip elements already
  // scanned (`done`, with their subtrees). The rest of the frame is walked
  // whole, the scoped part again included (cheaper than a filter per node).
  const done = new WeakSet();
  const scan = (roots, follow) => {
    const visit = (el) => {
      if (!B.spend(1)) return false;
      if (sensitive(el)) {
        for (const v of [el.value, el.getAttribute("value")]) {
          if (!v) continue;
          if (!B.charge(String(v).length)) return false;
          secrets.push(String(v));
        }
      }
      if (el.shadowRoot) roots.push(el.shadowRoot);
      if (!follow) return true;
      done.add(el);
      const home = el.getRootNode();
      for (const attr of el.attributes) {
        if (!B.charge(attr.value.length)) return false;
        for (const id of attr.value.split(/\s+/)) {
          const named = id && typeof home.getElementById === "function" ? home.getElementById(id) : null;
          if (named && !done.has(named)) roots.push(named);
        }
      }
      if (el.labels) for (const label of el.labels) if (!done.has(label)) roots.push(label);
      if (el.localName === "slot" && typeof el.assignedElements === "function") {
        for (const n of el.assignedElements({ flatten: true })) if (!done.has(n)) roots.push(n);
      }
      return true;
    };
    const skip = { acceptNode: (n) => (done.has(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT) };
    while (roots.length) {
      const root = roots.pop();
      if (root.nodeType === 1) {
        if (done.has(root)) continue;
        if (!visit(root)) return false;
      }
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, follow ? skip : null);
      for (let el = walker.nextNode(); el; el = walker.nextNode()) if (!visit(el)) return false;
    }
    return true;
  };
  if (scope) {
    if (!scan([...scope], true)) return cut("part");
    // The rest of the frame within what is left: its values are scrubbed
    // too when the whole frame fits (a page can copy a value anywhere).
    scan([document], false);
  } else if (!scan([document], false)) return cut("frame");
  const unique = new Set(secrets);
  secrets.length = 0;
  for (const v of unique) secrets.push(v);
  if (!secrets.length) return value;
  // The forms a value takes in text results: HTML-escaped (innerHTML),
  // whitespace-collapsed and cut (describe and strictError previews).
  const html = (v) => v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/\u00a0/g, "&nbsp;");
  for (const v of [...secrets]) {
    const flat = v.replace(/\s+/g, " ").trim();
    secrets.push(html(v), flat);
    if (flat.length > 12) secrets.push(flat.slice(0, 12));
  }
  for (let i = secrets.length - 1; i >= 0; i--) if (!secrets[i]) secrets.splice(i, 1);
  secrets.sort((x, y) => y.length - x.length);
  const scrub = (x) => {
    if (typeof x === "string") {
      let s = x;
      for (const k of secrets) s = k.length >= 4 ? s.split(k).join(MARK) : (s === k ? MARK : s);
      return s;
    }
    if (Array.isArray(x)) return x.map(scrub);
    if (x && typeof x === "object") {
      const out = {};
      for (const [k, v] of Object.entries(x)) out[scrub(k)] = scrub(v);
      return out;
    }
    return x;
  };
  return scrub(value);
}"#;

/// Turns `frame.observe {targetId, frameId?, method, args?}` into the
/// agent-world `frame.evaluate` that runs it, or refuses it.
pub fn evaluate_params(params: &Value) -> Result<Value, DriverError> {
    let method = params
        .get("method")
        .and_then(Value::as_str)
        .ok_or_else(|| DriverError::invalid("frame.observe: method must be a string"))?;
    if !OBSERVE_AGENT_METHODS.contains(&method) {
        let mut refusal = DriverError::new(
            ErrorCode::Forbidden,
            format!("frame.observe: {method} is not an observe method"),
        );
        refusal.error_name = Some(NOT_ALLOWED.to_owned());
        return Err(refusal);
    }
    let args = match params.get("args") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(args)) => args.clone(),
        Some(_) => return Err(DriverError::invalid("frame.observe: args must be an array")),
    };
    if args.len() > MAX_ARGS {
        return Err(DriverError::invalid(format!(
            "frame.observe: at most {MAX_ARGS} args, got {}",
            args.len()
        )));
    }
    if serde_json::to_vec(&args).map_or(usize::MAX, |bytes| bytes.len()) > MAX_ARGS_BYTES {
        return Err(DriverError::invalid("frame.observe: args are larger than 64 KiB"));
    }
    if !args.iter().all(numbers_in_range) {
        return Err(DriverError::invalid("frame.observe: numbers must be at most 1e9"));
    }
    if SELECTOR_METHODS.contains(&method) && args.iter().any(|arg| any_string(arg, &tests_a_value))
    {
        let mut refusal = DriverError::new(
            ErrorCode::Forbidden,
            format!("frame.observe: {method} selectors cannot test attribute values"),
        );
        refusal.error_name = Some(NOT_ALLOWED.to_owned());
        return Err(refusal);
    }
    let mut call_args = Vec::with_capacity(args.len() + 1);
    call_args.push(Value::String(method.to_owned()));
    call_args.extend(args);
    let mut evaluate = json!({
        "world": "agent",
        "source": OBSERVE_SOURCE,
        "args": call_args,
        "awaitPromise": true,
    });
    for key in ["targetId", "frameId", "timeoutMs"] {
        if let Some(value) = params.get(key) {
            evaluate[key] = value.clone();
        }
    }
    Ok(evaluate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_allowlisted_read_becomes_the_host_written_agent_call() {
        let params = json!({
            "targetId": "T", "frameId": "F", "method": "snapshot", "args": [{"base": 3}],
            "source": "attacker()", "world": "page", "handles": ["h1"],
        });
        let evaluate = evaluate_params(&params).unwrap();
        assert_eq!(evaluate["world"], "agent");
        assert_eq!(evaluate["source"], OBSERVE_SOURCE, "the caller cannot send code");
        assert_eq!(evaluate["args"], json!(["snapshot", {"base": 3}]));
        assert_eq!(evaluate["targetId"], "T");
        assert_eq!(evaluate["frameId"], "F");
        assert!(evaluate.get("handles").is_none());
    }

    #[test]
    fn a_function_outside_the_allowlist_is_refused() {
        for method in ["fill", "focus", "dispatchEvent", "scrollIntoViewIfNeeded", "hitTarget"] {
            let error = evaluate_params(&json!({"targetId": "T", "method": method})).unwrap_err();
            assert_eq!(error.code, ErrorCode::Forbidden, "{method}");
            assert_eq!(error.error_name.as_deref(), Some(NOT_ALLOWED), "{method}");
        }
        for method in ["constructor", "__proto__", "toString", ""] {
            assert!(evaluate_params(&json!({"method": method})).is_err(), "{method:?}");
        }
    }

    #[test]
    fn selectors_that_test_values_and_huge_numbers_are_refused() {
        for selector in [
            "input[type=password][value^=\"a\"]",
            "internal:attr=[value=\"x\"i]",
            "css=input[value='a']",
            "xpath=//input[@value=\"a\"]",
            "input[*|value^=a]",
            "input[\\76 alue^=a]",
        ] {
            let error =
                evaluate_params(&json!({"method": "queryAll", "args": [selector]})).unwrap_err();
            assert_eq!(error.error_name.as_deref(), Some(NOT_ALLOWED), "{selector}");
        }
        assert!(evaluate_params(&json!({"method": "queryAll", "args": ["input#pw"]})).is_ok());
        for allowed in
            ["[data-x]", "[data-value=a]", "internal:role=button[name=\"Go\"i]", "input[value]"]
        {
            assert!(
                evaluate_params(&json!({"method": "queryAll", "args": [allowed]})).is_ok(),
                "{allowed}"
            );
        }
        let huge = json!({"method": "snapshot", "args": [{"base": 9_007_199_254_740_991u64}]});
        assert_eq!(evaluate_params(&huge).unwrap_err().code, ErrorCode::Invalid);
        assert!(evaluate_params(&json!({"method": "snapshot", "args": [{"base": 40}]})).is_ok());
    }

    #[test]
    fn malformed_observe_params_are_invalid() {
        for params in [
            json!({"targetId": "T"}),
            json!({"method": 3}),
            json!({"method": "read", "args": "x"}),
            json!({"method": "read", "args": [0, 1, 2, 3, 4, 5, 6, 7, 8]}),
            json!({"method": "read", "args": ["x".repeat(70 * 1024)]}),
        ] {
            let error = evaluate_params(&params).unwrap_err();
            assert_eq!(error.code, ErrorCode::Invalid, "{params}");
        }
    }
}
