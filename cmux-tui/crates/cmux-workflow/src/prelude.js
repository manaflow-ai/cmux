// The workflow API, as Claude Code workflows define it, over the engine's
// native functions. Runs once before the script.
(() => {
  const native = globalThis.__cmuxNative;
  delete globalThis.__cmuxNative;
  const format = (value) => {
    if (typeof value === "string") return value;
    try { const text = JSON.stringify(value); return text === undefined ? String(value) : text; }
    catch { return String(value); }
  };
  const encode = (value) => {
    try { const text = JSON.stringify(value); return text === undefined ? "null" : text; }
    catch { return JSON.stringify(String(value)); }
  };
  const message = (error) => String(error && error.message !== undefined ? error.message : error);
  const say = (level) => (...args) => native.log(level, args.map(format).join(" "));
  globalThis.console = { log: say("log"), info: say("info"), warn: say("warn"), error: say("error"), debug: say("debug") };
  globalThis.log = (text) => native.log("log", format(text));

  // A resumed run must take the same path, so nothing may read the clock or
  // draw a random number. Pass times in args.
  const unavailable = (what) => () => {
    throw new Error(`${what} is not available in a workflow: a resumed run must take the same path (pass times in args)`);
  };
  Math.random = unavailable("Math.random()");
  const RealDate = Date;
  globalThis.Date = new Proxy(RealDate, {
    construct(target, list, newTarget) {
      if (list.length === 0) unavailable("new Date()")();
      return Reflect.construct(target, list, newTarget);
    },
    apply() { return unavailable("Date()")(); },
    get(target, key, receiver) {
      if (key === "now") return unavailable("Date.now()");
      return Reflect.get(target, key, receiver);
    },
  });

  const call = (name, args) => {
    const answer = JSON.parse(native.call(String(name), JSON.stringify(args ?? {})));
    if (answer.ok) return answer.value;
    const error = new Error(`${name}: ${answer.message}`);
    error.cmux = answer.error;
    throw error;
  };
  globalThis.cmux = new Proxy({ call }, {
    get(target, key) {
      if (key in target) return target[key];
      if (typeof key !== "string" || key === "then") return undefined;
      return (args) => call(key, args);
    },
  });

  let current = "";
  const pending = new Map();
  const start = (kind, input, options) => {
    if (options !== undefined && (options === null || typeof options !== "object" || Array.isArray(options))) {
      throw new Error(`${kind}() options must be an object`);
    }
    const answer = JSON.parse(native.start(kind, String(input), encode(options ?? {}), current));
    if (!answer.ok) {
      const error = new Error(answer.message);
      error.cmux = answer.error;
      throw error;
    }
    return new Promise((resolve, reject) => pending.set(answer.id, { resolve, reject }));
  };
  Object.defineProperty(globalThis, "__cmuxDeliver", {
    value: (id, ok, text) => {
      const waiter = pending.get(id);
      if (!waiter) return;
      pending.delete(id);
      const value = JSON.parse(text);
      if (ok) return waiter.resolve(value);
      const error = new Error(value.message);
      error.cmux = value;
      error.log = value.log;
      error.exit = value.exit;
      waiter.reject(error);
    },
  });
  // agent(prompt, {label, phase, schema, harness, model, effort, on}): the
  // final reply as text, or the validated object with a schema; null when the
  // agent failed for good.
  globalThis.agent = (prompt, options) => start("agent", prompt, options);
  // machine(command, {on}): {exit, log}; a non-zero exit rejects with an
  // Error whose exit and log say what happened.
  globalThis.machine = (command, options) => start("machine", command, options);
  // phase(title) groups later steps; phase(title, body) also runs body and
  // returns what it returns.
  globalThis.phase = (title, body) => {
    current = String(title);
    native.phase(current);
    return typeof body === "function" ? body() : undefined;
  };

  const MAX_ITEMS = 4096;
  const list = (items, what) => {
    const array = Array.from(items ?? []);
    if (array.length > MAX_ITEMS) throw new Error(`${what} takes at most ${MAX_ITEMS} items`);
    return array;
  };
  const dropped = (what) => (error) => {
    native.log("warn", `${what}: ${message(error)}`);
    return null;
  };
  // A barrier: every task's result, null for one that threw. Never rejects.
  globalThis.parallel = (thunks) => Promise.all(list(thunks, "parallel()").map((thunk, index) => {
    const fail = dropped(`parallel() task ${index}`);
    try { return Promise.resolve(typeof thunk === "function" ? thunk() : thunk).catch(fail); }
    catch (error) { return Promise.resolve(fail(error)); }
  }));
  // Each item through every stage on its own, with no barrier between
  // stages; a stage gets (previous, item, index). A stage that throws drops
  // its item to null.
  globalThis.pipeline = (items, ...stages) => Promise.all(list(items, "pipeline()").map(async (item, index) => {
    let value = item;
    for (const stage of stages) {
      try { value = await stage(value, item, index); }
      catch (error) { return dropped(`pipeline() item ${index}`)(error); }
    }
    return value;
  }));
  globalThis.workflow = () => { throw new Error("workflow() is not available in cmux workflows yet"); };
  globalThis.budget = Object.freeze({ total: null, spent: () => 0, remaining: () => Infinity });
  globalThis.args = native.args === undefined ? undefined : JSON.parse(native.args);
  Object.defineProperty(globalThis, "__cmuxMeta", { set(value) { native.meta(encode(value)); } });
  globalThis.__cmuxFinish = (promise) => promise.then(
    (value) => native.done(true, encode(value)),
    (error) => native.done(false, encode({
      code: "script.error",
      message: message(error),
      stack: error && error.stack ? String(error.stack) : undefined,
      cmux: error && error.cmux,
    })),
  );
})();
