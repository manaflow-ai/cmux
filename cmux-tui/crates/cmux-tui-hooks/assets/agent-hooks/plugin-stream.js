// cmux-tui-journal-plugin
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createInterface } from "node:readline";

// Installed inline so each provider still loads a single, self-contained plugin.
function journalPlugin(source) {
  let stream;
  let legacyRoute;
  let tail = Promise.resolve();
  let queued = 0;

  async function reply(iterator) {
    let timeout;
    try {
      return await Promise.race([
        iterator.next().then(({ value }) => value),
        new Promise((_, reject) => {
          timeout = setTimeout(() => reject(new Error("hook handoff timed out")), 5000);
        }),
      ]);
    } finally {
      clearTimeout(timeout);
    }
  }

  function oneShot(helper, event, payload, key, env) {
    return new Promise((resolve) => {
      const child = spawn(helper, [source, event], {
        env: { ...env, CMUX_TUI_PLUGIN_EVENT: key },
        stdio: ["pipe", "ignore", "ignore"], timeout: 5000,
      });
      child.on("error", resolve);
      child.on("close", resolve);
      child.stdin.on("error", () => {});
      child.stdin.end(payload);
    });
  }

  async function deliver(helper, event, payload, key, env) {
    const route = JSON.stringify([helper, env.CMUX_TUI_SOCKET, env.CMUX_TUI_TERMINAL_ID]);
    if (stream && stream.route !== route) {
      stream.child.stdin.end();
      stream = undefined;
    }
    if (legacyRoute !== route) {
      try {
        if (!stream) {
          const child = spawn(helper, ["--plugin-stream=" + source], {
            env, stdio: ["pipe", "pipe", "ignore"],
          });
          child.on("error", () => {});
          child.stdin.on("error", () => {});
          const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
          stream = { route, child, lines };
          if ((await reply(lines)) !== "ready") {
            legacyRoute = route; // An older helper exits without consuming an event.
            throw new Error("stream unsupported");
          }
        }
        const { child, lines } = stream;
        child.stdout.ref();
        child.stdin.write("[" + JSON.stringify(key) + "," + JSON.stringify(event) + "," + payload + "]\n");
        if ((await reply(lines)) !== "ok") throw new Error("handoff unconfirmed");
        // The plugin host may exit between events. EOF on its private pipe
        // then lets the helper finish draining the journal and exit too.
        child.unref();
        child.stdin.unref();
        child.stdout.unref();
        return;
      } catch (_) {
        if (stream) {
          stream.child.stdin.end();
          stream.child.stdout.destroy();
          stream.child.unref();
          stream = undefined;
        }
      }
    }
    // Reuse the identity even if the stream died just after queueing the event.
    await oneShot(helper, event, payload, key, env);
  }

  return (event, native) => {
    const helper = process.env.CMUX_TUI_HOOK;
    if (!helper || !process.env.CMUX_TUI_SOCKET || !process.env.CMUX_TUI_TERMINAL_ID) return;
    let payload;
    try {
      payload = JSON.stringify(native);
    } catch (_) {
      return;
    }
    if (!payload || Buffer.byteLength(payload) > 1048576) return;
    const key = Date.now() + ":" + randomBytes(16).toString("hex");
    const env = { ...process.env };
    queued++;
    tail = tail.then(() => deliver(helper, event, payload, key, env))
      .catch(() => {}).finally(() => { queued--; });
    // Keep normal callbacks asynchronous. A producer that awaits callbacks
    // applies backpressure once a burst has filled the queue.
    if (queued >= 64) return tail;
  };
}
