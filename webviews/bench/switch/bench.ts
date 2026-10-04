// Harness switch prototype against a live dev slot: `?mode=before` runs the production path
// (chat.new: await session/new, then select, then paint); `?mode=after` paints the pick at once
// from the cached catalog, takes a pre-created session from the warm pool (pool.ts) or starts one,
// and queues a prompt sent before the session is ready. Both use the production AcpmuxDirectClient.
// The dev server does not watch bench/: bump the ?v= in index.html after an edit.
// Open as /bench/switch/?mode=after#endpoint=...&token=...&cwd=... (the dev-slot fragment).
import { AcpmuxDirectClient, type AcpmuxHostConfig } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../../src/agent-session/acpmux/model";
import { WarmPool } from "./pool";

type Mark = { at: number; name: string; detail?: Record<string, unknown> };
const marks: Mark[] = [];
const mark = (name: string, detail?: Record<string, unknown>) => marks.push({ at: performance.now(), name, detail });
const bench = { marks, ready: false, mode: "", catalogMs: 0, error: "" } as Record<string, unknown> & { marks: Mark[] };
(window as unknown as { __switch: typeof bench }).__switch = bench;

const query = new URLSearchParams(location.search);
const mode = query.get("mode") === "after" ? "after" : "before";
bench.mode = mode;
const fragment = new URLSearchParams(location.hash.slice(1));
const cwd = fragment.get("cwd") ?? undefined;
const host: AcpmuxHostConfig = {
  protocolVersion: 1,
  transport: "acpmux-websocket",
  endpoint: fragment.get("endpoint") ?? "",
  token: fragment.get("token") ?? "",
  newSession: true,
  cwd,
};

const $ = (id: string) => document.getElementById(id)!;
let snapshot: AcpmuxSnapshot | undefined;
let catalog: AcpmuxSnapshot["catalog"] = [];
/** What the picker shows: the session's harness, or (after mode) the one just picked. */
let shown: { harness: string; model?: string; pending: boolean } | undefined;
/** After mode: the session the pick resolves to. */
let pending: { harness: string; ready: Promise<string | undefined> } | undefined;
let firstTokenFor: string | undefined;
/** After mode only. Declared before connect: the first snapshot renders before it exists. */
let pool: WarmPool | undefined;

const CATALOG_KEY = "bench.switch.catalog";
try {
  catalog = JSON.parse(localStorage.getItem(CATALOG_KEY) ?? "[]");
} catch {
  catalog = [];
}

function cachedModel(harness: string): string | undefined {
  const entry = catalog.find((candidate) => candidate.id === harness);
  return entry?.models?.[0]?.name ?? entry?.models?.[0]?.id;
}

function render() {
  const current = shown?.harness;
  const list = $("harnesses");
  if (!list.childElementCount)
    for (const entry of catalog) {
      const button = document.createElement("button");
      button.textContent = entry.name;
      button.dataset.harness = entry.id;
      button.addEventListener("pointerenter", () => hover(entry.id, true));
      button.addEventListener("pointerleave", () => hover(entry.id, false));
      button.addEventListener("click", () => void pick(entry.id));
      list.append(button);
    }
  const warm = pool?.warm();
  for (const button of list.querySelectorAll("button")) {
    button.setAttribute("aria-pressed", String(button.dataset.harness === current));
    button.dataset.warm = String(Boolean(warm?.get(button.dataset.harness!)?.ready));
  }
  const chip = $("chip");
  chip.dataset.pending = String(Boolean(shown?.pending));
  chip.dataset.harness = current ?? "";
  chip.textContent = shown ? `${catalog.find((c) => c.id === current)?.name ?? current} · ${shown.model ?? "…"}` : "";
}

function onSnapshot(next: AcpmuxSnapshot) {
  snapshot = next;
  bench.working = next.isWorking;
  bench.harness = next.summary?.harness;
  const summary = next.summary;
  // The session's own state wins once it is the one selected for the shown harness.
  if (summary?.harness && (!pending || summary.harness === pending.harness) && next.sessionId) {
    if (shown?.harness !== summary.harness || shown.pending || shown.model !== summary.model) {
      shown = { harness: summary.harness, model: summary.model ?? undefined, pending: false };
      mark("sessionShown", { harness: summary.harness, sessionId: next.sessionId });
    }
  }
  const assistant = [...next.rows].reverse().find((row) => row.kind === "assistant");
  if (firstTokenFor && assistant?.text && next.sessionId === firstTokenFor) {
    mark("firstToken", { sessionId: firstTokenFor });
    firstTokenFor = undefined;
  }
  $("reply").textContent = assistant?.text ?? "";
  render();
}

const client = await AcpmuxDirectClient.connect(host, onSnapshot);
// session/new without selecting: what the daemon's pool would do on its side.
const rawRequest = (method: string, params: unknown) =>
  (client as unknown as { request(m: string, p: unknown): Promise<any> }).request(method, params);
pool =
  mode === "after"
    ? new WarmPool(
        {
          create: async (harness) => {
            const result = await rawRequest("session/new", {
              ...(cwd ? { cwd } : {}),
              mcpServers: [],
              _meta: { acpmux: { harness } },
            });
            render();
            return result?.sessionId ? String(result.sessionId) : undefined;
          },
          discard: async (sessionId) =>
            void (await rawRequest("_acpmux/kill", { sessionId, purge: true }).catch(() => undefined)),
        },
        undefined,
        Number(query.get("idleMs") ?? 600_000),
      )
    : undefined;

const catalogStart = performance.now();
const fresh = await client.harnesses();
bench.catalogMs = performance.now() - catalogStart;
catalog = fresh;
localStorage.setItem(CATALOG_KEY, JSON.stringify(fresh));
await client.ensureSession();
mark("initialReady", { harness: snapshot?.summary?.harness });
render();
bench.ready = true;

function hover(harness: string, on: boolean) {
  if (!pool || harness === shown?.harness) return;
  if (on) pool.hold(harness, "hover");
  else pool.drop(harness, "hover");
}

async function pick(harness: string) {
  mark("pick", { harness, warm: pool?.warm().get(harness)?.ready ?? false });
  firstTokenFor = undefined;
  if (mode === "before") {
    // Production: chat.new awaits session/new, then selects; nothing paints until then.
    try {
      await client.create(harness, cwd);
    } catch (error) {
      mark("error", { message: String(error) });
    }
    return;
  }
  const previous = shown?.harness;
  shown = { harness, model: cachedModel(harness), pending: true };
  $("reply").textContent = "";
  render();
  requestAnimationFrame(() => mark("optimisticPaint", { harness }));
  const ready = (pool!.take(harness) ?? pool!.start(harness)).then(async (sessionId) => {
    if (!sessionId) throw new Error(`could not start ${harness}`);
    if (pending?.ready !== ready) return sessionId;
    await client.select(sessionId);
    return sessionId;
  });
  pending = { harness, ready };
  // Whatever was just left becomes the last-used harness, warm for the way back.
  if (previous && previous !== harness) pool!.hold(previous, "last-used");
  try {
    await ready;
    mark("ready", { harness });
  } catch (error) {
    mark("error", { message: String(error) });
    shown = previous ? { harness: previous, pending: false } : undefined;
    render();
  } finally {
    if (pending?.ready === ready) pending = undefined;
  }
}

async function submit(text: string) {
  mark("enter", { pendingHarness: pending?.harness ?? null, selected: client.selectedSession ?? null });
  if (mode === "after" && pending) {
    $("status").textContent = `Starting ${pending.harness}; your message sends when it is ready`;
    await pending.ready.catch(() => undefined);
  }
  const sessionId = client.selectedSession;
  firstTokenFor = sessionId;
  mark("promptSent", { sessionId, harness: snapshot?.summary?.harness });
  $("status").textContent = "";
  await client.send(text).catch((error) => mark("error", { message: String(error) }));
}

($("composer") as HTMLTextAreaElement).addEventListener("keydown", (event) => {
  if (event.key !== "Enter" || event.shiftKey) return;
  event.preventDefault();
  const field = event.currentTarget as HTMLTextAreaElement;
  const text = field.value;
  field.value = "";
  void submit(text);
});
