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
    let lower = selector.to_ascii_lowercase();
    lower.split('[').skip(1).any(|part| {
        let part = part.trim_start();
        part.strip_prefix("value").is_some_and(|rest| {
            matches!(rest.trim_start().chars().next(), Some('=' | '^' | '$' | '*' | '~' | '|'))
        })
    })
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
/// (substring for values of 4+ characters, whole string otherwise).
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
  const value = await A[m](...a);
  if (!["snapshot", "read", "describe", "strictError"].includes(m)) return value;
  const secrets = [];
  const walk = (root) => {
    for (const el of root.querySelectorAll("*")) {
      if (sensitive(el)) {
        if (el.value) secrets.push(String(el.value));
        const d = el.getAttribute("value");
        if (d) secrets.push(d);
      }
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  };
  walk(document);
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
    if SELECTOR_METHODS.contains(&method)
        && args.iter().filter_map(Value::as_str).any(tests_a_value)
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
