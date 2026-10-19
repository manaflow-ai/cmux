export interface DaytonaCall {
  readonly method: string;
  readonly url: URL;
  readonly body: unknown;
  readonly bytes: Uint8Array | null;
}

interface FakeSandbox {
  readonly id: string;
  state: "started" | "stopped" | "paused";
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

interface FakeSnapshot {
  readonly id: string;
  readonly name: string;
  state: "building" | "active";
  readonly sandboxId: string;
}

const jsonObject = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value) ? Object.fromEntries(Object.entries(value)) : {};

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
  ...(sandbox.autoStopInterval === 0 ? {} : { autoStopInterval: sandbox.autoStopInterval }),
  ...(sandbox.autoDeleteInterval < 0 ? {} : { autoDeleteInterval: sandbox.autoDeleteInterval }),
  ...(sandbox.ttlMinutes === 0 ? {} : { ttlMinutes: sandbox.ttlMinutes }),
  createdAt: sandbox.createdAt,
  updatedAt: sandbox.updatedAt,
  toolboxProxyUrl: sandbox.toolboxProxyUrl,
});

export function makeFakeDaytona() {
  const sandboxes = new Map<string, FakeSandbox>();
  const snapshots = new Map<string, FakeSnapshot>();
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
      return JSON.parse(text);
    } catch {
      return null;
    }
  };

  const main = async (request: Request, url: URL): Promise<Response> => {
    if (request.headers.get("authorization") !== "Bearer daytona-test-key") return Response.json({ message: "unauthorized" }, { status: 401 });
    const path = url.pathname.replace(/^\/api(?=\/)/u, "");
    const snapshotMatch = /^\/snapshots\/([^/]+)$/.exec(path);
    if (snapshotMatch?.[1] !== undefined) {
      const snapshotKey = decodeURIComponent(snapshotMatch[1]);
      const snapshot = snapshots.get(snapshotKey) ?? [...snapshots.values()].find((candidate) => candidate.name === snapshotKey);
      if (snapshot === undefined) return Response.json({ message: "not found" }, { status: 404 });
      if (request.method === "DELETE") {
        snapshots.delete(snapshot.id);
        return new Response(null, { status: 204 });
      }
      if (request.method === "GET") {
        if (snapshot.state === "building") snapshot.state = "active";
        return Response.json({ id: snapshot.id, name: snapshot.name, state: snapshot.state });
      }
    }
    const match = /^\/sandbox\/([^/]+)(?:\/(start|stop|pause|resize|snapshot|toolbox-proxy-url))?$/.exec(path);
    if (path === "/sandbox" && request.method === "POST") {
      const body = jsonObject(await json(request));
      if (typeof body.snapshot === "string" && ("cpu" in body || "memory" in body || "disk" in body)) {
        return Response.json({ message: "resources cannot be set with a snapshot" }, { status: 400 });
      }
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
        labels: Object.fromEntries(Object.entries(jsonObject(body.labels)).map(([key, value]) => [key, String(value)])),
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
    if (request.method === "GET" && operation === "toolbox-proxy-url") return Response.json({ url: sandbox.toolboxProxyUrl });
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
    if (request.method === "POST" && operation === "pause") {
      sandbox.state = "paused";
      sandbox.updatedAt = "2026-10-18T00:00:03.000Z";
      return Response.json(bodyFor(sandbox));
    }
    if (request.method === "POST" && operation === "resize") {
      const body = jsonObject(await json(request));
      if (typeof body.cpu === "number") sandbox.cpu = body.cpu;
      if (typeof body.memory === "number") sandbox.memory = body.memory;
      if (typeof body.disk === "number") sandbox.disk = body.disk;
      return Response.json(bodyFor(sandbox));
    }
    if (request.method === "POST" && operation === "snapshot") {
      const body = jsonObject(await json(request));
      const name = typeof body.name === "string" ? body.name : `snapshot-${sandbox.id}`;
      const snapshot: FakeSnapshot = { id: `snap-${nextId++}`, name, state: "building", sandboxId: sandbox.id };
      snapshots.set(snapshot.id, snapshot);
      return Response.json({ id: snapshot.id, name: snapshot.name, state: snapshot.state });
    }
    return Response.json({ message: "not found" }, { status: 404 });
  };

  const toolbox = async (request: Request, url: URL): Promise<Response> => {
    if (request.headers.get("authorization") !== "Bearer daytona-test-key") return Response.json({ message: "unauthorized" }, { status: 401 });
    const match = /^\/toolbox\/([^/]+)\/(process\/execute|files\/download|files\/upload-v2|files|files\/permissions)$/.exec(url.pathname);
    if (match?.[1] === undefined || match[2] === undefined || !sandboxes.has(decodeURIComponent(match[1]))) return Response.json({ message: "not found" }, { status: 404 });
    const sandboxId = decodeURIComponent(match[1]);
    const operation = match[2];
    if (operation === "files/permissions" && request.method === "POST") return new Response(null, { status: 200 });
    if (operation === "process/execute" && request.method === "POST") {
      const body = jsonObject(await json(request));
      const envs = jsonObject(body.envs);
      const command = typeof envs.CMUX_DAYTONA_COMMAND === "string" ? envs.CMUX_DAYTONA_COMMAND : String(body.command ?? "");
      const stdout = btoa(`ran: ${command}\n`);
      return Response.json({ result: `__CMUX_EXIT__0\n__CMUX_STDOUT__\n${stdout}\n__CMUX_STDERR__\n`, exitCode: 0 });
    }
    const path = url.searchParams.get("path") ?? "";
    const key = `${sandboxId}\u0000${path}`;
    if (operation === "files/upload-v2" && request.method === "POST") {
      const contentType = request.headers.get("content-type") ?? "";
      if (!contentType.startsWith("multipart/form-data;")) return Response.json({ message: "multipart required" }, { status: 400 });
      const boundary = /boundary=([^;]+)/u.exec(contentType)?.[1];
      if (boundary === undefined) return Response.json({ message: "boundary required" }, { status: 400 });
      const bytes = new Uint8Array(await request.clone().arrayBuffer());
      const text = new TextDecoder().decode(bytes);
      const start = text.indexOf("\r\n\r\n");
      const end = text.lastIndexOf(`\r\n--${boundary}`);
      if (start < 0 || end < start) return Response.json({ message: "file part required" }, { status: 400 });
      files.set(key, bytes.slice(start + 4, end));
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
        .filter((entry, index, all) => entry !== undefined && entry.length > 0 && all.indexOf(entry) === index)
        .flatMap((name) => (name === undefined ? [] : [{ name, isDir: false }]));
      return Response.json(entries);
    }
    return Response.json({ message: "not found" }, { status: 404 });
  };

  const fetch: typeof globalThis.fetch = async (input, init) => {
    const request = input instanceof Request ? input : new Request(input, init);
    const url = new URL(request.url);
    const bytes = await record(request);
    let parsed: unknown = null;
    if (bytes !== null && request.headers.get("content-type")?.includes("json") === true) {
      try {
        parsed = JSON.parse(new TextDecoder().decode(bytes));
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
