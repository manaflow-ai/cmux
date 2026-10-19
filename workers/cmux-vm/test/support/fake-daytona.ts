export interface DaytonaCall {
  readonly method: string;
  readonly url: URL;
  readonly body: unknown;
  readonly bytes: Uint8Array | null;
}

interface FakeSandbox {
  readonly id: string;
  state: "started" | "stopped";
  cpu: number;
  memory: number;
  disk: number;
  autoStopInterval: number;
  autoDeleteInterval: number;
  ttlMinutes: number;
  readonly labels: Record<string, string>;
  readonly createdAt: string;
  updatedAt: string;
  readonly toolboxProxyUrl: string;
}

const jsonObject = (value: unknown): Record<string, unknown> => (typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {});

const snapshotResources = (snapshot: string | undefined): { cpu: number; memory: number; disk: number } => {
  switch (snapshot) {
    case "daytona-medium":
      return { cpu: 2, memory: 4, disk: 8 };
    case "daytona-large":
      return { cpu: 4, memory: 8, disk: 10 };
    default:
      return { cpu: 1, memory: 1, disk: 3 };
  }
};

const bodyFor = (sandbox: FakeSandbox) => ({
  id: sandbox.id,
  name: sandbox.id,
  state: sandbox.state,
  cpu: sandbox.cpu,
  memory: sandbox.memory,
  disk: sandbox.disk,
  autoStopInterval: sandbox.autoStopInterval,
  autoDeleteInterval: sandbox.autoDeleteInterval,
  ttlMinutes: sandbox.ttlMinutes,
  createdAt: sandbox.createdAt,
  updatedAt: sandbox.updatedAt,
  toolboxProxyUrl: sandbox.toolboxProxyUrl,
});

export function makeFakeDaytona() {
  const sandboxes = new Map<string, FakeSandbox>();
  const files = new Map<string, Uint8Array>();
  const calls: DaytonaCall[] = [];
  let nextId = 1;

  const record = async (request: Request): Promise<Uint8Array | null> => {
    const bytes = new Uint8Array(await request.clone().arrayBuffer());
    if (bytes.length === 0) return null;
    try {
      return bytes;
    } catch {
      return bytes;
    }
  };

  const json = async (request: Request): Promise<unknown> => {
    const text = await request.clone().text();
    if (text.length === 0) return null;
    try {
      return JSON.parse(text) as unknown;
    } catch {
      return null;
    }
  };

  const main = async (request: Request, url: URL): Promise<Response> => {
    const path = url.pathname.replace(/^\/api(?=\/)/u, "");
    if (request.method === "DELETE" && /^\/snapshots\/[^/]+$/.test(path)) return new Response(null, { status: 204 });
    const match = /^\/sandbox\/([^/]+)(?:\/(start|stop|resize|snapshot))?$/.exec(path);
    if (path === "/sandbox" && request.method === "POST") {
      const body = jsonObject(await json(request));
      const resources = snapshotResources(typeof body.snapshot === "string" ? body.snapshot : undefined);
      const sandbox: FakeSandbox = {
        id: `sbx-${nextId++}`,
        state: "started",
        cpu: typeof body.cpu === "number" ? body.cpu : resources.cpu,
        memory: typeof body.memory === "number" ? body.memory : resources.memory,
        disk: typeof body.disk === "number" ? body.disk : resources.disk,
        autoStopInterval: typeof body.autoStopInterval === "number" ? body.autoStopInterval : 0,
        autoDeleteInterval: typeof body.autoDeleteInterval === "number" ? body.autoDeleteInterval : -1,
        ttlMinutes: typeof body.ttlMinutes === "number" ? body.ttlMinutes : 0,
        labels: jsonObject(body.labels) as Record<string, string>,
        createdAt: "2026-10-18T00:00:00.000Z",
        updatedAt: "2026-10-18T00:00:00.000Z",
        toolboxProxyUrl: "https://proxy.daytona.test/toolbox",
      };
      sandboxes.set(sandbox.id, sandbox);
      return Response.json(bodyFor(sandbox));
    }
    if (match?.[1] === undefined) return Response.json({ message: "not found" }, { status: 404 });
    const sandbox = sandboxes.get(decodeURIComponent(match[1]));
    if (sandbox === undefined) return Response.json({ message: "not found" }, { status: 404 });
    const operation = match[2];
    if (request.method === "GET" && operation === undefined) return Response.json(bodyFor(sandbox));
    if (request.method === "DELETE" && operation === undefined) {
      sandboxes.delete(sandbox.id);
      return new Response(null, { status: 204 });
    }
    if (request.method === "POST" && operation === "start") {
      sandbox.state = "started";
      sandbox.updatedAt = "2026-10-18T00:00:01.000Z";
      return Response.json(bodyFor(sandbox));
    }
    if (request.method === "POST" && operation === "stop") {
      sandbox.state = "stopped";
      sandbox.updatedAt = "2026-10-18T00:00:02.000Z";
      return Response.json(bodyFor(sandbox));
    }
    if (request.method === "POST" && operation === "resize") {
      const body = jsonObject(await json(request));
      if (typeof body.cpu === "number") sandbox.cpu = body.cpu;
      if (typeof body.memory === "number") sandbox.memory = body.memory;
      if (typeof body.disk === "number") sandbox.disk = body.disk;
      return Response.json(bodyFor(sandbox));
    }
    if (request.method === "POST" && operation === "snapshot") return Response.json(bodyFor(sandbox));
    return Response.json({ message: "not found" }, { status: 404 });
  };

  const toolbox = async (request: Request, url: URL): Promise<Response> => {
    const match = /^\/toolbox\/([^/]+)\/(process\/execute|files\/download|files\/upload-v2|files|files\/permissions)$/.exec(url.pathname);
    if (match?.[1] === undefined || match[2] === undefined || !sandboxes.has(decodeURIComponent(match[1]))) return Response.json({ message: "not found" }, { status: 404 });
    const sandboxId = decodeURIComponent(match[1]);
    const operation = match[2];
    if (operation === "files/permissions" && request.method === "POST") return new Response(null, { status: 200 });
    if (operation === "process/execute" && request.method === "POST") {
      const body = jsonObject(await json(request));
      return Response.json({ result: `ran: ${String(body.command ?? "")}\n`, exitCode: 0 });
    }
    const path = url.searchParams.get("path") ?? "";
    const key = `${sandboxId}\u0000${path}`;
    if (operation === "files/upload-v2" && request.method === "POST") {
      files.set(key, new Uint8Array(await request.clone().arrayBuffer()));
      return Response.json({ name: path.split("/").at(-1) ?? path, path, type: "file" });
    }
    if (operation === "files/download" && request.method === "GET") {
      const bytes = files.get(key);
      if (bytes === undefined) return Response.json({ message: "not found" }, { status: 404 });
      const range = request.headers.get("range");
      const matchRange = range === null ? null : /^bytes=(\d+)-(\d+)$/.exec(range);
      if (matchRange?.[1] !== undefined && matchRange[2] !== undefined) {
        const start = Number(matchRange[1]);
        const end = Math.min(Number(matchRange[2]), bytes.length - 1);
        return new Response(bytes.slice(start, end + 1), { status: 206, headers: { "content-range": `bytes ${start}-${end}/${bytes.length}` } });
      }
      return new Response(bytes);
    }
    if (operation === "files" && request.method === "GET") {
      const prefix = path.endsWith("/") ? path : `${path}/`;
      const entries = [...files.keys()]
        .filter((entry) => entry.startsWith(`${sandboxId}\u0000${prefix}`))
        .map((entry) => entry.slice(`${sandboxId}\u0000${prefix}`.length).split("/")[0])
        .filter((entry, index, all) => entry.length > 0 && all.indexOf(entry) === index)
        .map((name) => ({ name, isDir: false }));
      return Response.json(entries);
    }
    return Response.json({ message: "not found" }, { status: 404 });
  };

  const fetch = async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    const bytes = await record(request);
    let parsed: unknown = null;
    if (bytes !== null && request.headers.get("content-type")?.includes("json") === true) {
      try {
        parsed = JSON.parse(new TextDecoder().decode(bytes)) as unknown;
      } catch {
        parsed = null;
      }
    }
    calls.push({ method: request.method, url, body: parsed, bytes });
    return url.hostname === "proxy.daytona.test" ? toolbox(request, url) : main(request, url);
  };

  return {
    fetch,
    calls,
    sandboxes,
    files,
    callsTo: (method: string, path: RegExp) => calls.filter((call) => call.method === method && path.test(call.url.pathname)),
  };
}
