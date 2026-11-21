// The real acpmux daemon behind the real agent pane, for browser tests that must not trust a
// stand-in daemon's idea of how acpmux behaves (model, effort and access picks; a new chat's
// start). Leo, 2026-11-17: "we need to test out more of these permission related combinations in ci
// and whatnot so things are as people would expect".
//
// What runs:
//   - `acpmux daemon run` (ACPMUX_BIN, else cmux-tui/target/{debug,release}/acpmux) on its own
//     ACPMUX_HOME, hermetic as cmux-tui/crates/acpmux/tests/support/daemon_env.rs makes its daemons:
//     nothing from the host's environment, a bare PATH, HOME under the scratch directory. Its
//     harnesses are acpmux's own stand-ins: `claude` is tests/fake_claude.py as Claude Code's
//     stream-json (claude-stdio), `codex` is tests/fake_codex_app_server.py as `codex app-server`
//     (the in-process Codex bridge). acpmux builds every model, effort and mode option from them as
//     it does for the real CLIs.
//   - a relay in this process standing in for the app's Swift transport (AgentPaneTransport): the
//     page dials it with the listener token, and the relay dials the daemon as the app's pane does,
//     with the LocalApp token in the first frame (server/local_app.rs) and the person proof right
//     after it (hub/person.rs), under a person key the daemon took at spawn (`--person-key-fd`).
//     So the page is the person, as in the app, and its picks reach acpmux unchanged.
//
// `restart()` stops the daemon and starts a new one on the same home (a new port, LocalApp token
// and person key, as an app relaunch gives); the relay keeps its address, so the page's own
// reconnect finds it.
import { createHmac, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const repo = path.resolve(import.meta.dir, "../../..");
const acpmuxTests = path.join(repo, "cmux-tui/crates/acpmux/tests");

/** The acpmux binary these tests run, or undefined when this host has none built. */
export function acpmuxBinary(env: Record<string, string | undefined> = process.env): string | undefined {
  if (env.ACPMUX_BIN) return env.ACPMUX_BIN;
  const targets = [env.CARGO_TARGET_DIR, path.join(repo, "cmux-tui/target")].filter(Boolean) as string[];
  for (const target of targets)
    for (const profile of ["debug", "release"]) {
      const bin = path.join(target, profile, "acpmux");
      if (existsSync(bin)) return bin;
    }
  return undefined;
}

/** Whether this run must have the daemon: the CI job that builds it sets CMUX_REAL_ACPMUX=1. */
export function realAcpmuxRequired(env: Record<string, string | undefined> = process.env): boolean {
  return env.CMUX_REAL_ACPMUX === "1";
}

const ACPMUX_PROTOCOL = "acpmux.v1";
const TOKEN_PREFIX = "acpmux.token.";

type Frame = { id?: number | string; method?: string; params?: any; result?: any; error?: any };

export type RealAcpmux = {
  /** The relay's WebSocket endpoint and listener token, for the page's `#endpoint=…&token=…`. */
  endpoint: string;
  token: string;
  /** The folder new chats start in. */
  cwd: string;
  home: string;
  /** Every frame the page sent the daemon, in order (after the relay's own two). */
  sent: Frame[];
  /** Every frame the daemon sent the page. */
  received: Frame[];
  /** The page's socket count since start (a reconnect adds one). */
  connections: () => number;
  /** A JSON-RPC call on the relay's own person connection, outside the page. */
  call: (method: string, params?: unknown) => Promise<any>;
  restart: () => Promise<void>;
  stop: () => Promise<void>;
  log: () => string;
};

export type RealAcpmuxOptions = {
  /** The page's origin (the Vite dev server), the one dev origin the daemon trusts. */
  pageOrigin: string;
  /** Harness acpmux starts a new chat on. */
  defaultHarness?: "claude" | "codex";
  /** Merged into config.json. */
  config?: Record<string, unknown>;
  /** Extra environment for the daemon (its stand-in agents read FAKE_* variables). */
  env?: Record<string, string>;
  /** The cmux settings file (cmux.json) acpmux reads at each new chat; none by default (every default). */
  settings?: Record<string, unknown>;
};

/**
 * The stand-in Codex's catalog (FAKE_CODEX_CATALOG): a real one's shape, `model/list` rows with id
 * and model, one the default, each model with its own levels and default level. GPT-6 Astra is the
 * default and GPT-6.1 Sol sits beside it.
 */
function levels(...ids: string[]) {
  return ids.map((reasoningEffort) => ({ reasoningEffort, description: `${reasoningEffort} reasoning` }));
}

export const CODEX_CATALOG = [
  {
    id: "gpt-6-astra",
    model: "gpt-6-astra",
    displayName: "GPT-6 Astra",
    isDefault: true,
    supportedReasoningEfforts: levels("low", "medium", "high"),
    defaultReasoningEffort: "medium",
  },
  {
    id: "gpt-6.1-sol",
    model: "gpt-6.1-sol",
    displayName: "GPT-6.1 Sol",
    supportedReasoningEfforts: levels("low", "medium", "high", "xhigh"),
    defaultReasoningEffort: "medium",
  },
];

function freePort(): number {
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("") });
  const port = server.port;
  void server.stop(true);
  return port!;
}

/** The person proof acpmux checks (hub/person.rs `person_proof`). */
function personProof(key: string, transport: string, nonce: string, connection: string): string {
  const mac = createHmac("sha256", Buffer.from(key, "hex"));
  mac.update(
    Buffer.concat([
      Buffer.from("acpmux-person-v1"),
      Buffer.from([0]),
      Buffer.from(transport),
      Buffer.from([0]),
      Buffer.from(nonce),
      Buffer.from([0]),
      Buffer.from(connection),
    ]),
  );
  return mac.digest("hex");
}

export async function startRealAcpmux(options: RealAcpmuxOptions): Promise<RealAcpmux> {
  const bin = acpmuxBinary();
  if (!bin) throw new Error("no acpmux binary: set ACPMUX_BIN or build cmux-tui's acpmux");
  const scratch = mkdtempSync(path.join(os.tmpdir(), "real-acpmux-"));
  const home = path.join(scratch, "acpmux");
  const userHome = path.join(scratch, "home");
  const cwd = path.join(scratch, "work", "uploader");
  const binDir = path.join(scratch, "bin");
  for (const dir of [home, userHome, cwd, binDir]) mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(cwd, "README.md"), "# uploader\n");
  const python = Bun.which("python3");
  if (!python) throw new Error("python3 is needed for acpmux's stand-in agents");
  const codex = path.join(binDir, "codex");
  writeFileSync(codex, `#!/bin/sh\nexec '${python}' '${path.join(acpmuxTests, "fake_codex_app_server.py")}' "$@"\n`);
  chmodSync(codex, 0o755);
  const claude = path.join(binDir, "claude");
  writeFileSync(claude, `#!/bin/sh\nexec '${python}' '${path.join(acpmuxTests, "fake_claude.py")}' "$@"\n`);
  chmodSync(claude, 0o755);
  const config = {
    harnesses: {
      claude: { kind: "claude-stdio", argv: [claude] },
      codex: { argv: [codex, "app-server"] },
    },
    defaultHarness: options.defaultHarness ?? "codex",
    permissionPolicy: "ask",
    webRoots: [path.dirname(cwd)],
    autoResumeDelaysMs: [],
    ...options.config,
  };
  writeFileSync(path.join(home, "config.json"), JSON.stringify(config, null, 2));
  if (options.settings) writeFileSync(path.join(userHome, "cmux.json"), JSON.stringify(options.settings, null, 2));
  const catalog = path.join(scratch, "codex-catalog.json");
  writeFileSync(catalog, JSON.stringify(CODEX_CATALOG));

  const listenerToken = randomBytes(24).toString("hex");
  let daemonPort = 0;
  let key = "";
  let daemon: ReturnType<typeof Bun.spawn> | undefined;
  let logText = "";
  const env: Record<string, string> = {
    PATH: [path.dirname(python), "/usr/bin", "/bin"].join(":"),
    HOME: userHome,
    TMPDIR: os.tmpdir(),
    ACPMUX_HOME: home,
    ACPMUX_SOCKET: path.join(home, "acpmux.sock"),
    // The cmux settings file: absent unless a test gives one (every default, as the app ships).
    CMUX_NEXT_CONFIG_FILE: path.join(userHome, "cmux.json"),
    ACPMUX_SESSION_CPU_CLASS: "normal",
    ACPMUX_SPARE_HARNESS: "0",
    FAKE_CODEX_CATALOG: catalog,
    ...options.env,
  };

  async function startDaemon() {
    daemonPort = freePort();
    key = randomBytes(32).toString("hex");
    const keyFile = path.join(scratch, "person.key");
    writeFileSync(keyFile, key, { mode: 0o600 });
    // The key on fd 3, which the daemon reads and closes (`--person-key-fd`).
    daemon = Bun.spawn(
      [
        "/bin/sh",
        "-c",
        `exec "$0" daemon run --listen 127.0.0.1:${daemonPort} --token ${listenerToken} --allow-dev-origin "$1" --dev --person-key-fd 3 3<"$2"`,
        bin!,
        options.pageOrigin,
        keyFile,
      ],
      { cwd, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" },
    );
    for (const stream of [daemon.stdout, daemon.stderr] as ReadableStream<Uint8Array>[]) {
      void (async () => {
        const decoder = new TextDecoder();
        for await (const chunk of stream) logText += decoder.decode(chunk);
      })();
    }
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      if (daemon.exitCode !== null) throw new Error(`acpmux exited ${daemon.exitCode}:\n${logText}`);
      const open = await fetch(`http://127.0.0.1:${daemonPort}/`).then(
        () => true,
        () => false,
      );
      if (open && existsSync(path.join(home, "run", "localapp.token"))) {
        rmSync(keyFile, { force: true });
        return;
      }
      // fixed-wait: the daemon process says nothing when its port opens; this paces the readiness probe.
      await Bun.sleep(50);
    }
    throw new Error(`acpmux did not listen on ${daemonPort}:\n${logText}`);
  }

  /** A daemon connection that is the person, as the app's transport makes one. */
  function dial(onFrame: (text: string) => void, onClose: () => void): Promise<WebSocket> {
    const localAppToken = readFileSync(path.join(home, "run", "localapp.token"), "utf8").trim();
    const socket = new WebSocket(`ws://127.0.0.1:${daemonPort}/`, {
      protocols: [ACPMUX_PROTOCOL, `${TOKEN_PREFIX}${listenerToken}`],
      headers: { Origin: options.pageOrigin },
    } as any);
    return new Promise((resolve, reject) => {
      let stage: "open" | "init" | "prove" | "ready" = "open";
      socket.onopen = () => resolve(socket);
      socket.onerror = (event) => stage === "open" && reject(new Error(`relay dial failed: ${String(event)}`));
      socket.onclose = onClose;
      socket.onmessage = (event) => {
        const text = String(event.data);
        if (stage === "init") {
          const frame = JSON.parse(text) as Frame;
          const challenge = frame.result?._meta?.acpmux?.personChallenge;
          if (frame.id !== undefined && challenge) {
            stage = "prove";
            onFrame(text);
            socket.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: "relay-person",
                method: "_acpmux/person_prove",
                params: { proof: personProof(key, "app", challenge.nonce, challenge.connection) },
              }),
            );
            return;
          }
        }
        if (stage === "prove") {
          const frame = JSON.parse(text) as Frame;
          if (frame.id === "relay-person") {
            stage = "ready";
            (socket as any).proven();
            if (frame.error || frame.result?.person === false) logText += `\nrelay: person proof refused ${text}\n`;
            return;
          }
        }
        onFrame(text);
      };
      // Frames after the initialize wait for the proof: it must be the connection's second request.
      let held: string[] | undefined = [];
      (socket as any).proven = () => {
        for (const text of held ?? []) socket.send(text);
        held = undefined;
      };
      (socket as any).sendLater = (text: string) => (held ? held.push(text) : socket.send(text));
      // The first frame the caller sends is the initialize the relay carries the token in.
      (socket as any).sendFirst = (frame: Frame) => {
        stage = "init";
        frame.params = frame.params ?? {};
        frame.params._meta = { ...frame.params._meta };
        frame.params._meta.acpmux = { ...frame.params._meta.acpmux, localAppToken };
        socket.send(JSON.stringify(frame));
      };
    });
  }

  const sent: Frame[] = [];
  const received: Frame[] = [];
  let connections = 0;
  type Link = { upstream?: WebSocket; queue: string[]; first: boolean };
  const relay = Bun.serve<Link>({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      const offered = (request.headers.get("sec-websocket-protocol") ?? "").split(",").map((p) => p.trim());
      if (!offered.includes(`${TOKEN_PREFIX}${listenerToken}`)) return new Response("token", { status: 401 });
      const ok = server.upgrade(request, {
        data: { queue: [], first: true },
        headers: { "Sec-WebSocket-Protocol": ACPMUX_PROTOCOL },
      });
      return ok ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      async open(ws) {
        connections += 1;
        try {
          const upstream = await dial(
            (text) => {
              try {
                received.push(JSON.parse(text));
              } catch {}
              ws.send(text);
            },
            () => ws.close(),
          );
          ws.data.upstream = upstream;
          for (const text of ws.data.queue.splice(0)) forward(ws.data, text);
        } catch {
          ws.close();
        }
      },
      message(ws, raw) {
        const text = String(raw);
        if (!ws.data.upstream) ws.data.queue.push(text);
        else forward(ws.data, text);
      },
      close(ws) {
        ws.data.upstream?.close();
      },
    },
  });
  function forward(link: Link, text: string) {
    let frame: Frame | undefined;
    try {
      frame = JSON.parse(text);
    } catch {}
    if (frame) sent.push(frame);
    if (link.first && frame?.method === "initialize") {
      link.first = false;
      (link.upstream as any).sendFirst(frame);
      return;
    }
    link.first = false;
    (link.upstream as any).sendLater(text);
  }

  /// The relay's own person connection, for reads and setup outside the page.
  let own: { socket: WebSocket; next: number; waiting: Map<number, (frame: Frame) => void> } | undefined;
  async function ownConnection() {
    if (own && own.socket.readyState === WebSocket.OPEN) return own;
    const waiting = new Map<number, (frame: Frame) => void>();
    const socket = await dial(
      (text) => {
        const frame = JSON.parse(text) as Frame;
        if (typeof frame.id === "number") waiting.get(frame.id)?.(frame);
      },
      () => {},
    );
    own = { socket, next: 1, waiting };
    await new Promise<void>((resolve) => {
      waiting.set(0, () => resolve());
      (socket as any).sendFirst({ jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: 1 } });
    });
    return own;
  }
  async function call(method: string, params: unknown = {}) {
    const link = await ownConnection();
    const id = link.next++;
    return new Promise<any>((resolve, reject) => {
      // fixed-wait: a deadline on the answer, never a wait for it.
      const timer = setTimeout(() => reject(new Error(`${method}: no answer`)), 20_000);
      link.waiting.set(id, (frame) => {
        clearTimeout(timer);
        link.waiting.delete(id);
        if (frame.error) reject(new Error(`${method}: ${JSON.stringify(frame.error)}`));
        else resolve(frame.result);
      });
      (link.socket as any).sendLater(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  async function stopDaemon() {
    own?.socket.close();
    own = undefined;
    if (!daemon) return;
    daemon.kill("SIGTERM");
    // fixed-wait: the bound on a clean exit before SIGKILL.
    const exited = await Promise.race([daemon.exited.then(() => true), Bun.sleep(10_000).then(() => false)]);
    if (!exited) daemon.kill("SIGKILL");
    await daemon.exited;
    daemon = undefined;
  }

  await startDaemon();
  // The person trusts the chats' folder, as one who has worked there has (no Trust card).
  await call("acp.trust.set", { cwd, level: "trusted" });
  return {
    endpoint: `ws://127.0.0.1:${relay.port}/`,
    token: listenerToken,
    cwd,
    home,
    sent,
    received,
    connections: () => connections,
    call,
    async restart() {
      await stopDaemon();
      // The page's sockets ended with the daemon's; its reconnect dials the relay again.
      await startDaemon();
    },
    async stop() {
      await stopDaemon();
      await relay.stop(true);
      rmSync(scratch, { recursive: true, force: true });
    },
    log: () => logText,
  };
}

export const NEW_TAB = "new&newtab";

/** The pane's dev page against `daemon`: `#endpoint=…&token=…&cwd=…&<hash>`; a New Tab (`new&newtab`, as the app opens one) by default. */
export function paneUrl(pageBase: string, daemon: RealAcpmux, hash = NEW_TAB): string {
  const endpoint = encodeURIComponent(daemon.endpoint);
  return `${pageBase}/#endpoint=${endpoint}&token=${daemon.token}&cwd=${encodeURIComponent(daemon.cwd)}&${hash}`;
}
