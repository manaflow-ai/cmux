//! Workflow-only bindings on the existing QuickJS context. No extra runtime or
//! filesystem/network capability is introduced here.

use rquickjs::{Ctx, Function, Object};
use serde_json::{Map, Value};

use super::{Request, failure};

pub(super) fn install<'js>(
    ctx: &Ctx<'js>,
    request: impl Fn(Request) -> String + Clone + 'static,
    inputs: Value,
) -> rquickjs::Result<Function<'js>> {
    let native = Object::new(ctx.clone())?;
    let start = request.clone();
    native.set(
        "start",
        Function::new(ctx.clone(), move |kind: String, prompt: String, options: String| {
            let options = match serde_json::from_str::<Map<String, Value>>(&options) {
                Ok(options) => options,
                Err(_) => {
                    return failure("usage.invalid", "workflow activity options must be an object");
                }
            };
            start(Request::ActivityStart { kind, prompt, options })
        })?,
    )?;
    native.set(
        "wait",
        Function::new(ctx.clone(), move |ids: String| {
            let ids = match serde_json::from_str::<Vec<String>>(&ids) {
                Ok(ids) if !ids.is_empty() => ids,
                _ => return failure("usage.invalid", "workflow wait needs activity ids"),
            };
            request(Request::ActivityWait { ids })
        })?,
    )?;
    ctx.globals().set("__workflowNative", native)?;
    ctx.globals().set("__workflowInputs", inputs.to_string())?;
    ctx.eval(PRELUDE)
}

/// Claude workflows allow one leading `export const meta` followed by an async
/// function body (including top-level return). Remove only that export token,
/// never text inside strings/comments or an unrelated later statement.
pub(super) fn body(script: &str) -> String {
    let mut rest = script.trim_start_matches('\u{feff}');
    loop {
        rest = rest.trim_start();
        if let Some(comment) = rest.strip_prefix("//") {
            let Some(end) = comment.find('\n') else { return script.into() };
            let Some(start) = end.checked_add(1) else { return script.into() };
            rest = comment.get(start..).unwrap_or_default();
        } else if let Some(comment) = rest.strip_prefix("/*") {
            let Some(end) = comment.find("*/") else { return script.into() };
            let Some(start) = end.checked_add(2) else { return script.into() };
            rest = comment.get(start..).unwrap_or_default();
        } else {
            break;
        }
    }
    let Some(after_export) = rest.strip_prefix("export") else { return script.into() };
    if !after_export.starts_with(char::is_whitespace) {
        return script.into();
    }
    let Some(after_const) = after_export.trim_start().strip_prefix("const") else {
        return script.into();
    };
    if !after_const.starts_with(char::is_whitespace) {
        return script.into();
    }
    let Some(after_meta) = after_const.trim_start().strip_prefix("meta") else {
        return script.into();
    };
    if !after_meta.trim_start().starts_with('=') {
        return script.into();
    }
    let Some(offset) = script.len().checked_sub(rest.len()) else { return script.into() };
    format!("{}{}", script.get(..offset).unwrap_or_default(), after_export)
}

const PRELUDE: &str = r#"
(() => {
  const native = globalThis.__workflowNative;
  const inputs = globalThis.__workflowInputs;
  delete globalThis.__workflowNative;
  delete globalThis.__workflowInputs;
  globalThis.args = JSON.parse(inputs);
  const nondeterministic = () => { throw new Error('workflow replay forbids clocks and randomness'); };
  Object.defineProperty(globalThis, 'Date', {value: nondeterministic, writable: false, configurable: false});
  for (const name of ['performance', 'crypto', 'Temporal', 'WeakRef', 'FinalizationRegistry']) {
    Object.defineProperty(globalThis, name, {value: undefined, writable: false, configurable: false});
  }
  Object.defineProperty(Math, 'random', {value: nondeterministic, writable: false, configurable: false});
  const pending = new Map();
  const rejected = new Map();
  const errorFrom = (kind, details, message) => {
    const error = new Error(`${kind}: ${message ?? details?.message ?? JSON.stringify(details)}`);
    error.cmux = details;
    return error;
  };
  const activity = (kind, prompt, options = {}) => new Promise((resolve, reject) => {
    let answer;
    try { answer = JSON.parse(native.start(kind, String(prompt), JSON.stringify(options))); }
    catch (error) { answer = {ok: false, message: String(error)}; }
    if (!answer.ok) {
      const key = Symbol();
      const item = {answer, kind, resolve, reject};
      pending.set(key, item);
      rejected.set(key, item);
      return;
    }
    const id = answer.value?.id;
    if (typeof id !== 'string' || !id || pending.has(id)) {
      reject(new Error('workflow start returned a missing or duplicate activity id'));
      return;
    }
    pending.set(id, {kind, resolve, reject});
  });
  globalThis.agent = (prompt, options) => activity('agent', prompt, options);
  globalThis.machine = (command, options) => activity('machine', command, options);
  globalThis.phase = async (_title, work) => await work();
  globalThis.parallel = (tasks) => Promise.all(tasks.map(task => typeof task === 'function' ? task() : task));
  globalThis.pipeline = async (items, work) => {
    const results = [];
    for (const item of items) results.push(await work(item));
    return results;
  };
  return (inspect) => {
    if (inspect) return pending.size;
    const failure = rejected.entries().next();
    if (!failure.done) {
      const [key, next] = failure.value;
      rejected.delete(key);
      pending.delete(key);
      next.reject(errorFrom(next.kind, next.answer.error, next.answer.message));
      return 1;
    }
    if (!pending.size) return 0;
    const answer = JSON.parse(native.wait(JSON.stringify(Array.from(pending.keys()))));
    if (!answer.ok) throw errorFrom('workflow wait', answer.error, answer.message);
    const {id, outcome} = answer.value ?? {};
    const next = pending.get(id);
    if (!next || !outcome || typeof outcome !== 'object') {
      throw new Error('workflow wait returned an unknown activity or missing outcome');
    }
    if (Object.prototype.hasOwnProperty.call(outcome, 'Ok')) {
      pending.delete(id);
      next.resolve(outcome.Ok);
    } else if (Object.prototype.hasOwnProperty.call(outcome, 'Err')) {
      pending.delete(id);
      next.reject(errorFrom(next.kind, outcome.Err));
    } else {
      throw new Error('workflow wait returned an invalid outcome');
    }
    return 1;
  };
})();
"#;
