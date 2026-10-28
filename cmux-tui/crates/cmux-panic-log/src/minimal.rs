//! The panic log with std alone, for a process that links std and libc
//! only (the holder, `cmux-holder holder-panics.jsonl`).
//!
//! The line is the one [`crate::install`] writes: the same keys, the same
//! `crash_keys` object, the same trace keys ([`crate::trace_context`]'s
//! `role`, `uptime_ms`, `scopes` and `scope_depth`), the same size caps and the same owner-only,
//! no-follow append, so the app's `RustPanicForwarder` reads both alike.
//! Only the encoder differs: the JSON is written and escaped by hand (RFC
//! 8259 section 7: `"`, `\` and the control characters below U+0020 are
//! escaped, everything else is copied as UTF-8), not through serde_json.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use crate::crash_keys::{self, Key, Snapshot};

/// One field's value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    /// A JSON string.
    Text(String),
    /// A JSON number.
    Number(u64),
    /// `true` or `false`.
    Bool(bool),
}

impl From<&str> for Value {
    fn from(text: &str) -> Self {
        Self::Text(text.to_owned())
    }
}

impl From<String> for Value {
    fn from(text: String) -> Self {
        Self::Text(text)
    }
}

impl From<u64> for Value {
    fn from(number: u64) -> Self {
        Self::Number(number)
    }
}

impl From<u32> for Value {
    fn from(number: u32) -> Self {
        Self::Number(u64::from(number))
    }
}

impl From<bool> for Value {
    fn from(flag: bool) -> Self {
        Self::Bool(flag)
    }
}

/// Fields every line carries besides the panic itself, in order. A field
/// named like one of the panic's own keys is left out (the panic's wins,
/// as in [`crate::record`]).
pub type Fields = Vec<(&'static str, Value)>;

/// The keys the panic writes itself.
const PANIC_KEYS: [&str; 11] = [
    "message",
    "location",
    "thread",
    "at_ms",
    "test",
    "backtrace",
    "crash_keys",
    "role",
    "uptime_ms",
    "scopes",
    "scope_depth",
];

/// What a line carries from the process at the panic besides the panic:
/// its crash keys and its trace keys. Copies only, no allocation.
#[derive(Clone, Copy, Debug)]
pub struct Context {
    /// The process's [`crash_keys`] (`crash_keys`, when any is set).
    pub keys: Snapshot,
    /// The role the process traces as (`role`).
    pub role: Option<cmux_trace::Role>,
    /// Time since the trace black box started (`uptime_ms`).
    pub uptime_ns: Option<u64>,
    /// The thread's open trace scopes (`scopes` and `scope_depth`, when any).
    pub scopes: cmux_trace::ScopeStack,
}

impl Context {
    /// The calling thread's context: a panic hook reads it on the panicking
    /// thread.
    pub fn current() -> Self {
        Self {
            keys: crash_keys::snapshot(),
            role: cmux_trace::process_role(),
            uptime_ns: cmux_trace::process_uptime_ns(),
            scopes: cmux_trace::scope_stack(),
        }
    }
}

/// Install a hook that appends each panic to `path`, then runs the previous
/// hook. `is_test_thread` marks lines from a debug test trigger (`"test": true`).
pub fn install(path: PathBuf, fields: Fields, is_test_thread: fn(&str) -> bool) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let panic = crate::Panic::capture(info);
        let test = is_test_thread(&panic.thread);
        let line = line(
            &fields,
            &panic.message,
            &panic.location,
            &panic.thread,
            test,
            panic.backtrace,
            &Context::current(),
        );
        append(&path, &line);
        previous(info);
    }));
}

/// One whole log line, its newline included: `fields`, then the panic's
/// own keys, then `crash_keys` when `context` has any, then its trace keys.
pub fn line(
    fields: &Fields,
    message: &str,
    location: &str,
    thread: &str,
    test: bool,
    mut backtrace: String,
    context: &Context,
) -> String {
    crate::truncate_backtrace(&mut backtrace);
    let mut out = String::with_capacity(256 + message.len() + backtrace.len());
    let mut object = Object::open(&mut out);
    for (key, value) in fields.iter().filter(|(key, _)| !PANIC_KEYS.contains(key)) {
        object.key(key);
        match value {
            Value::Text(text) => push_string(object.out, text),
            Value::Number(number) => push_number(object.out, u128::from(*number)),
            Value::Bool(flag) => object.out.push_str(if *flag { "true" } else { "false" }),
        }
    }
    object.key("message");
    push_string(object.out, message);
    object.key("location");
    push_string(object.out, location);
    object.key("thread");
    push_string(object.out, thread);
    object.key("at_ms");
    push_number(object.out, crate::now_ms());
    object.key("test");
    object.out.push_str(if test { "true" } else { "false" });
    object.key("backtrace");
    push_string(object.out, &backtrace);
    if !context.keys.is_empty() {
        object.key("crash_keys");
        push_crash_keys(object.out, &context.keys);
    }
    push_trace(&mut object, context);
    object.close();
    out.push('\n');
    out
}

/// Append one [`line`], unless the log is full. Never panics.
pub fn append(path: &Path, line: &str) {
    crate::append_line(&|| crate::open_log(path), line.as_bytes());
}

/// [`crate::trace_context`]'s keys: `role` and `uptime_ms` when the process
/// traces, `scopes` (innermost first) and `scope_depth` when any scope is open.
fn push_trace(object: &mut Object<'_>, context: &Context) {
    if let Some(role) = context.role {
        object.key("role");
        push_string(object.out, role.as_str());
    }
    if let Some(uptime_ns) = context.uptime_ns {
        object.key("uptime_ms");
        push_number(object.out, u128::from(uptime_ns / 1_000_000));
    }
    if context.scopes.depth() > 0 {
        object.key("scopes");
        object.out.push('[');
        for (index, name) in context.scopes.names().enumerate() {
            if index > 0 {
                object.out.push(',');
            }
            push_string(object.out, name);
        }
        object.out.push(']');
        object.key("scope_depth");
        push_number(object.out, u128::from(context.scopes.depth()));
    }
}

/// [`Snapshot::to_json`]'s object: each set key by name, and the hung
/// threads' count and kinds.
fn push_crash_keys(out: &mut String, keys: &Snapshot) {
    let mut object = Object::open(out);
    for key in Key::ALL {
        let value = keys.get(key);
        if value != 0 {
            object.key(key.name());
            push_number(object.out, u128::from(value));
        }
    }
    let count = keys.hung_threads().count();
    if count > 0 {
        object.key("hung_threads");
        push_number(object.out, count as u128);
        object.key("hung_thread_kinds");
        object.out.push('[');
        for (index, thread) in keys.hung_threads().enumerate() {
            if index > 0 {
                object.out.push(',');
            }
            push_number(object.out, u128::from(thread.kind));
        }
        object.out.push(']');
    }
    object.close();
}

/// A JSON object being written: commas between members.
struct Object<'a> {
    out: &'a mut String,
    first: bool,
}

impl<'a> Object<'a> {
    fn open(out: &'a mut String) -> Self {
        out.push('{');
        Self { out, first: true }
    }

    /// `"key":`, after a comma unless it is the first member.
    fn key(&mut self, key: &str) {
        if !std::mem::take(&mut self.first) {
            self.out.push(',');
        }
        push_string(self.out, key);
        self.out.push(':');
    }

    fn close(self) {
        self.out.push('}');
    }
}

fn push_number(out: &mut String, number: u128) {
    // Writing to a String cannot fail.
    let _ = write!(out, "{number}");
}

/// `text` as a JSON string (RFC 8259 section 7).
fn push_string(out: &mut String, text: &str) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            control if control < '\u{20}' => {
                let _ = write!(out, "\\u{:04x}", u32::from(control));
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    /// No crash key, no trace: this test thread holds no scope.
    fn no_context() -> Context {
        Context {
            keys: Snapshot::default(),
            role: None,
            uptime_ns: None,
            scopes: cmux_trace::scope_stack(),
        }
    }

    fn parse(line: &str) -> serde_json::Value {
        assert!(line.ends_with('\n') && line.matches('\n').count() == 1, "{line:?}");
        serde_json::from_str(line).unwrap_or_else(|error| panic!("{error}: {line:?}"))
    }

    #[test]
    fn a_line_is_one_json_object_with_every_text_escaped() {
        let awkward = "quote \" back \\ nl \n cr \r tab \t bell \u{07} nul \u{0} del \u{7f} é 🦀";
        let fields: Fields = vec![
            ("process", "cmux-holder".into()),
            ("holder_pid", 4242u32.into()),
            ("awkward", awkward.into()),
            ("flag", true.into()),
            // The panic's own key wins.
            ("message", "from fields".into()),
        ];
        let line = line(
            &fields,
            awkward,
            "src/holder.rs:1:2",
            "holder-loop",
            false,
            "0: frame".into(),
            &no_context(),
        );
        let record = parse(&line);
        assert_eq!(record["process"], "cmux-holder");
        assert_eq!(record["holder_pid"], 4242);
        assert_eq!(record["awkward"], awkward);
        assert_eq!(record["flag"], true);
        assert_eq!(record["message"], awkward);
        assert_eq!(line.matches("\"message\"").count(), 1, "{line}");
        assert_eq!(record["location"], "src/holder.rs:1:2");
        assert_eq!(record["thread"], "holder-loop");
        assert_eq!(record["test"], false);
        assert_eq!(record["backtrace"], "0: frame");
        assert!(record["at_ms"].as_u64().is_some_and(|at| at > 0), "{record}");
        assert!(record.get("crash_keys").is_none(), "no key set, no object: {record}");
        assert!(record.get("role").is_none(), "no trace, no role: {record}");
        assert!(record.get("scopes").is_none(), "no scope open: {record}");
    }

    #[test]
    fn a_line_carries_the_trace_keys_of_the_json_writer() {
        let context = Context {
            role: Some(cmux_trace::Role::Holder),
            uptime_ns: Some(2_500_000_000),
            ..no_context()
        };
        let record = parse(&line(&Fields::new(), "m", "l", "t", false, String::new(), &context));
        assert_eq!(record["role"], "holder");
        assert_eq!(record["uptime_ms"], 2500);
        #[cfg(feature = "json")]
        {
            let json = crate::trace_context(context.role, context.uptime_ns, &context.scopes);
            assert_eq!(record["role"], json["role"]);
            assert_eq!(record["uptime_ms"], json["uptime_ms"]);
        }
    }

    #[test]
    fn a_line_carries_the_crash_keys_object_of_the_json_writer() {
        let mut keys = Snapshot::default();
        keys.set(Key::ActionId, 12);
        keys.set(Key::DaemonEpoch, 3);
        let keys = Snapshot::parse(&{
            let mut buffer = [0u8; crash_keys::MAX_RECORD_BYTES];
            let len = keys.write_line(&mut buffer);
            format!("{} hung_kind_0=2 hung_kind_1=5", std::str::from_utf8(&buffer[..len]).unwrap())
        })
        .unwrap();
        let context = Context { keys, ..no_context() };
        let record = parse(&line(&Fields::new(), "m", "l", "t", true, String::new(), &context));
        assert_eq!(
            record["crash_keys"],
            serde_json::json!({
                "action_id": 12, "daemon_epoch": 3, "hung_threads": 2, "hung_thread_kinds": [2, 5]
            })
        );
        #[cfg(feature = "json")]
        assert_eq!(record["crash_keys"], keys.to_json());
        assert_eq!(record["test"], true);
    }

    #[test]
    fn a_long_backtrace_is_cut_on_a_char_boundary() {
        let backtrace = "é".repeat(crate::MAX_BACKTRACE_BYTES);
        let record = parse(&line(&Fields::new(), "m", "l", "t", false, backtrace, &no_context()));
        let kept = record["backtrace"].as_str().unwrap();
        assert!(
            kept.len() <= crate::MAX_BACKTRACE_BYTES && kept.len() + 2 > crate::MAX_BACKTRACE_BYTES
        );
        assert!(kept.chars().all(|ch| ch == 'é'));
    }
}
