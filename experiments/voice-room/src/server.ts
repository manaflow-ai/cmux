// The Voice Room server: the room page, WebRTC signaling, the transcript, OptChat-style memory and
// the cheap-model digest that turns asks into Chief tasks. It listens on loopback only. Sharing the
// room with the tailnet is `--share`: `tailscale serve` puts it on this Mac's tailnet HTTPS name
// (a secure context, so other people's browsers may use their mic and camera) and adds the
// visitor's Tailscale identity to each request.

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ServerWebSocket } from "bun";
import { CrossMicDedupe } from "./dedupe.ts";
import { extractTasks, modelSummarize } from "./digest.ts";
import { type Entry, type EntryKind, RoomMemory, renderNode } from "./memory.ts";
import { anthropicComplete, type Complete, costUSD, HAIKU_4_5_PRICE, metered, type ModelUsage } from "./model.ts";
import { isLoopback, parseClientMessage, type Peer, Roster } from "./room.ts";
import { cliSendToChief, type SendToChief, TaskBoard } from "./tasks.ts";

export interface RoomConfig {
  port: number;
  dataDir: string;
  /** Who speaks from this Mac (the native app's transcript and local browsers). */
  selfName: string;
  /** The room's address for people and for Chief messages. */
  publicUrl: string;
  complete: Complete;
  sendToChief: SendToChief;
  retentionHours: number;
  /** Quiet time after the last line before a digest runs. */
  digestDelayMs: number;
  /** A digest runs at least this often while people talk. */
  digestMaxDelayMs: number;
  publicDir: string;
}

interface SocketData {
  peerId: string;
  /** The cmux app's capture socket: gets room events, is not in the roster. */
  observer: boolean;
}

export function startRoom(config: RoomConfig) {
  mkdirSync(config.dataDir, { recursive: true });
  const logPath = join(config.dataDir, "log.jsonl");
  const usage: ModelUsage = { inputTokens: 0, outputTokens: 0, calls: 0 };
  const complete = metered(config.complete, usage);
  const startedAt = Date.now();
  const roster = new Roster();
  const dedupe = new CrossMicDedupe();
  const sockets = new Map<string, ServerWebSocket<SocketData>>();
  let paused = false;
  let digestedThrough = 0;
  let digestTimer: ReturnType<typeof setTimeout> | null = null;
  let firstUndigestedAt = 0;
  let digesting = false;
  let observerCount = 0;

  const memory = new RoomMemory({
    summarize: modelSummarize(complete),
    persist: (entry) => appendFileSync(logPath, `${JSON.stringify(entry)}\n`),
  });
  if (existsSync(logPath)) {
    const saved = readFileSync(logPath, "utf8")
      .split("\n")
      .filter(Boolean)
      .flatMap((line): Entry[] => {
        try {
          return [JSON.parse(line) as Entry];
        } catch {
          return [];
        }
      });
    memory.restore(saved);
    digestedThrough = saved.at(-1)?.id ?? 0;
  }
  const prune = () => memory.prune(Date.now() - config.retentionHours * 3_600_000);
  prune();
  setInterval(prune, 3_600_000);

  const board = new TaskBoard(config.sendToChief, () => broadcast({ t: "tasks", tasks: board.tasks }));

  function broadcast(message: unknown) {
    const text = JSON.stringify(message);
    for (const socket of sockets.values()) socket.send(text);
  }

  function usageReport() {
    const hours = Math.max((Date.now() - startedAt) / 3_600_000, 1 / 60);
    const cost = costUSD(usage, HAIKU_4_5_PRICE);
    return { ...usage, costUSD: cost, costPerHourUSD: cost / hours };
  }

  function state() {
    return {
      t: "state",
      paused,
      peers: roster.list(),
      entries: memory.entries.slice(-200),
      view: memory.render(),
      tasks: board.tasks,
      usage: usageReport(),
      selfName: config.selfName,
      publicUrl: config.publicUrl,
    };
  }

  function scheduleDigest() {
    const now = Date.now();
    if (!firstUndigestedAt) firstUndigestedAt = now;
    if (digestTimer) clearTimeout(digestTimer);
    const wait = Math.max(0, Math.min(config.digestDelayMs, firstUndigestedAt + config.digestMaxDelayMs - now));
    digestTimer = setTimeout(() => void digest(), wait);
  }

  async function digest() {
    if (digesting) return scheduleDigest();
    digesting = true;
    digestTimer = null;
    firstUndigestedAt = 0;
    try {
      const fresh = memory.since(digestedThrough);
      if (fresh.length === 0) return;
      const through = fresh.at(-1)!.id;
      await memory.settle();
      const context = memory
        .view()
        .filter((node) => node.start + node.n - 1 <= digestedThrough)
        .map(renderNode)
        .join("\n");
      const tasks = await extractTasks(complete, context, fresh);
      digestedThrough = through;
      if (tasks.length) await board.add(tasks);
      broadcast({ t: "view", view: memory.render(), usage: usageReport() });
    } catch (error) {
      broadcast({ t: "error", message: `digest: ${error instanceof Error ? error.message : String(error)}` });
    } finally {
      digesting = false;
    }
  }

  /** One line from a transcriber (native app, a browser, a test). Returns false while paused. */
  function hear(speaker: string, text: string, level: number, kind: EntryKind = "speech", at = Date.now()) {
    if (paused) return false;
    const clean = text.trim();
    if (!clean) return true;
    if (kind === "speech") {
      const verdict = dedupe.check({ speaker, text: clean, at, level });
      if (verdict.kind === "duplicate") return true;
      if (verdict.kind === "replace" && verdict.previous.entryId) {
        memory.reattribute(verdict.previous.entryId, speaker);
        broadcast({ t: "reattribute", id: verdict.previous.entryId, speaker });
        return true;
      }
    }
    const entry = memory.append(kind, speaker, clean, at);
    if (kind === "speech") {
      const heard = { speaker, text: clean, at, level, entryId: entry.id };
      dedupe.remember(heard);
    }
    broadcast({ t: "entry", entry });
    scheduleDigest();
    return true;
  }

  function setPaused(on: boolean, by: string) {
    if (paused === on) return;
    paused = on;
    broadcast({ t: "paused", paused, by });
  }

  function identity(request: Request): string {
    // Set by `tailscale serve`; a loopback caller without them is this Mac's own person.
    const login = request.headers.get("tailscale-user-login");
    const name = request.headers.get("tailscale-user-name");
    return name || login || config.selfName;
  }

  function isTrustedRequest(request: Request, port: number): boolean {
    return trustedRequest(request, port, config.publicUrl);
  }

  const files: Record<string, string> = {
    "/": "index.html",
    "/room.js": "room.js",
    "/room.css": "room.css",
  };
  const types: Record<string, string> = {
    html: "text/html; charset=utf-8",
    js: "text/javascript; charset=utf-8",
    css: "text/css; charset=utf-8",
  };

  const server = Bun.serve<SocketData>({
    hostname: "127.0.0.1",
    port: config.port,
    async fetch(request, server) {
      const address = server.requestIP(request)?.address ?? "";
      if (!isLoopback(address)) return new Response("forbidden", { status: 403 });
      // Any web page the person has open can reach loopback: refuse other origins (a page on
      // another site POSTing "Chief, ..." lines or opening the socket) and other hosts (DNS rebinding).
      if (!isTrustedRequest(request, server.port ?? config.port)) return new Response("forbidden", { status: 403 });
      const url = new URL(request.url);
      if (url.pathname === "/ws") {
        if (url.searchParams.get("observer") === "1") {
          // The cmux app's capture: hears the pause state, is not a person in the room.
          if (server.upgrade(request, { data: { peerId: `o${(observerCount += 1)}`, observer: true } })) return undefined;
          return new Response("upgrade failed", { status: 400 });
        }
        const name = identity(request) === config.selfName ? url.searchParams.get("name") || config.selfName : identity(request);
        const peer = roster.join(name, request.headers.get("tailscale-user-login") ?? "this Mac");
        if (server.upgrade(request, { data: { peerId: peer.id, observer: false } })) return undefined;
        roster.leave(peer.id);
        return new Response("upgrade failed", { status: 400 });
      }
      if (request.method === "POST" && !request.headers.get("content-type")?.startsWith("application/json")) {
        return new Response("expected application/json", { status: 415 });
      }
      if (url.pathname === "/api/state" && request.method === "GET") return Response.json(state());
      if (url.pathname === "/api/transcript" && request.method === "POST") {
        const body = (await request.json().catch(() => null)) as {
          text?: unknown;
          level?: unknown;
          kind?: unknown;
        } | null;
        if (!body || typeof body.text !== "string") return Response.json({ error: "text required" }, { status: 400 });
        const kind: EntryKind = body.kind === "screen" ? "screen" : "speech";
        const accepted = hear(identity(request), body.text.slice(0, 4000), typeof body.level === "number" ? body.level : 0, kind);
        return Response.json({ accepted, paused });
      }
      if (url.pathname === "/api/pause" && request.method === "POST") {
        const body = (await request.json().catch(() => null)) as { on?: unknown } | null;
        if (typeof body?.on !== "boolean") return Response.json({ error: "on required" }, { status: 400 });
        setPaused(body.on, identity(request));
        return Response.json({ paused });
      }
      if (url.pathname === "/api/digest" && request.method === "POST") {
        await digest();
        return Response.json({ view: memory.render(), tasks: board.tasks, usage: usageReport() });
      }
      const file = files[url.pathname];
      if (file && request.method === "GET") {
        const extension = file.split(".").pop() ?? "html";
        return new Response(Bun.file(join(config.publicDir, file)), {
          headers: { "content-type": types[extension] ?? "application/octet-stream", "cache-control": "no-store" },
        });
      }
      return new Response("not found", { status: 404 });
    },
    websocket: {
      open(socket) {
        sockets.set(socket.data.peerId, socket);
        if (socket.data.observer) {
          socket.send(JSON.stringify({ t: "paused", paused, by: "" }));
          return;
        }
        const peer = roster.get(socket.data.peerId)!;
        socket.send(JSON.stringify({ ...state(), t: "welcome", you: peer }));
        broadcast({ t: "peers", peers: roster.list(), joined: peer.id });
        memory.append("join", peer.name, `joined from ${peer.device}`);
      },
      message(socket, raw) {
        const message = parseClientMessage(String(raw));
        const from = socket.data.peerId;
        const peer = roster.get(from);
        if (!message || !peer) return;
        switch (message.t) {
          case "signal": {
            const target = roster.relayTarget(from, message.to);
            if (target) sockets.get(target.id)?.send(JSON.stringify({ t: "signal", from, data: message.data }));
            break;
          }
          case "state":
            roster.update(from, message);
            broadcast({ t: "peers", peers: roster.list() });
            break;
          case "speech":
            hear(peer.name, message.text, message.level ?? 0);
            break;
          case "pause":
            setPaused(message.on, peer.name);
            break;
          case "task.send":
            void board.dispatch(message.id);
            break;
          case "task.dismiss":
            board.dismiss(message.id);
            break;
        }
      },
      close(socket) {
        sockets.delete(socket.data.peerId);
        if (socket.data.observer) return;
        const peer = roster.leave(socket.data.peerId);
        broadcast({ t: "peers", peers: roster.list(), left: socket.data.peerId });
        if (peer) memory.append("join", peer.name, "left");
      },
    },
  });

  return { server, memory, board, usage: usageReport, hear, digest, setPaused, isPaused: () => paused, roster: () => roster.list() as Peer[] };
}

/**
 * A request the room may act on: its Host is this server (loopback on `port`) or the room's own
 * public address, and a browser's Origin, when sent, is one of those too. The native app sends no
 * Origin. Exported for tests.
 */
export function trustedRequest(request: Request, port: number, publicUrl: string): boolean {
  const hosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`]);
  try {
    hosts.add(new URL(publicUrl).host);
  } catch {
    // An unparsable public address adds nothing.
  }
  const host = request.headers.get("host") ?? "";
  if (!hosts.has(host)) return false;
  const origin = request.headers.get("origin");
  if (origin === null) return true;
  try {
    // `tailscale serve` may forward the public Host or rewrite it to loopback; either way the
    // page's origin must be one of this room's own addresses.
    return hosts.has(new URL(origin).host);
  } catch {
    return false;
  }
}

async function tailscaleSelf(bin: string): Promise<{ login: string; dnsName: string } | null> {
  try {
    const child = Bun.spawn([bin, "status", "--json"], { stdout: "pipe", stderr: "ignore" });
    const status = JSON.parse(await new Response(child.stdout).text()) as {
      Self?: { DNSName?: string; UserID?: number };
      User?: Record<string, { LoginName?: string; DisplayName?: string }>;
    };
    const user = status.User?.[String(status.Self?.UserID)];
    return { login: user?.DisplayName || user?.LoginName || "", dnsName: (status.Self?.DNSName ?? "").replace(/\.$/, "") };
  } catch {
    return null;
  }
}

if (import.meta.main) {
  const args = new Set(process.argv.slice(2));
  const env = process.env;
  const port = Number(env.VOICE_ROOM_PORT ?? 4788);
  const sharePort = Number(env.VOICE_ROOM_SHARE_PORT ?? 4789);
  const tailscale = env.VOICE_ROOM_TAILSCALE ?? "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
  const self = await tailscaleSelf(tailscale);
  const share = args.has("--share");
  if (share) {
    const child = Bun.spawn([tailscale, "serve", "--bg", `--https=${sharePort}`, `http://127.0.0.1:${port}`], {
      stdout: "inherit",
      stderr: "inherit",
    });
    if ((await child.exited) !== 0) console.error("voice-room: tailscale serve failed; the room stays on this Mac only");
  }
  const publicUrl = share && self?.dnsName ? `https://${self.dnsName}:${sharePort}/` : `http://127.0.0.1:${port}/`;
  const token = env.VOICE_ROOM_MODEL_TOKEN ?? env.ANTHROPIC_AUTH_TOKEN ?? env.ANTHROPIC_API_KEY ?? "";
  const chief = env.VOICE_ROOM_CHIEF ?? "cli";
  const room = startRoom({
    port,
    dataDir: env.VOICE_ROOM_DATA ?? join(homedir(), "Library/Application Support/cmux/voice-room/default"),
    selfName: env.VOICE_ROOM_NAME ?? (self?.login || "me"),
    publicUrl,
    complete: anthropicComplete({
      baseUrl: env.VOICE_ROOM_MODEL_URL ?? env.ANTHROPIC_BASE_URL ?? "https://api.anthropic.com",
      token,
      model: env.VOICE_ROOM_MODEL ?? "claude-haiku-4-5",
      claudeCodeCompat: (env.VOICE_ROOM_CLAUDE_CODE_COMPAT ?? "1") === "1",
    }),
    sendToChief:
      chief === "off"
        ? async (task) => console.log(`voice-room: task (not sent, VOICE_ROOM_CHIEF=off): ${task.title}`)
        : cliSendToChief(publicUrl, env.VOICE_ROOM_CMUX ?? "cmux"),
    retentionHours: Number(env.VOICE_ROOM_RETENTION_HOURS ?? 24),
    digestDelayMs: Number(env.VOICE_ROOM_DIGEST_DELAY_MS ?? 5000),
    digestMaxDelayMs: Number(env.VOICE_ROOM_DIGEST_MAX_DELAY_MS ?? 30000),
    publicDir: join(import.meta.dir, "../public"),
  });
  console.log(`voice-room: http://127.0.0.1:${room.server.port}/ (room address: ${publicUrl})`);
}
