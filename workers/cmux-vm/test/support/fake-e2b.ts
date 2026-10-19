/** Small HTTP-level E2B fake: platform REST plus the envd Connect/file routes used by the adapter. */

interface FakeSandbox {
  readonly sandboxID: string;
  readonly envdAccessToken: string;
  readonly domain: string;
  readonly templateID: string;
  readonly startedAt: string;
  state: "running" | "paused";
  readonly metadata: Record<string, string>;
  readonly files: Map<string, Uint8Array>;
}

interface Call {
  readonly method: string;
  readonly url: string;
  readonly headers: Headers;
  readonly body: Uint8Array | null;
}

const encoder = new TextEncoder();

const json = (body: unknown, status = 200) => Response.json(body, { status });

const frame = (message: unknown, flags = 0): Uint8Array => {
  const payload = encoder.encode(JSON.stringify(message));
  const output = new Uint8Array(payload.length + 5);
  output[0] = flags;
  new DataView(output.buffer).setUint32(1, payload.length);
  output.set(payload, 5);
  return output;
};

const framedResponse = (messages: ReadonlyArray<{ readonly message: unknown; readonly flags?: number }>) => {
  const parts = messages.map(({ message, flags }) => frame(message, flags));
  const body = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    body.set(part, offset);
    offset += part.length;
  }
  return new Response(body, { status: 200, headers: { "content-type": "application/connect+json" } });
};

const base64 = (value: string): string => {
  const bytes = encoder.encode(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
};

export function makeFakeE2b() {
  const calls: Call[] = [];
  const sandboxes = new Map<string, FakeSandbox>();
  const snapshots = new Set<string>();
  let nextSandbox = 1;
  let nextSnapshot = 1;
  const fail = new Map<string, number>();

  const fetch: typeof globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    const body = request.body === null ? null : new Uint8Array(await request.arrayBuffer());
    const url = new URL(request.url);
    calls.push({ method: request.method, url: request.url, headers: new Headers(request.headers), body });
    const key = `${request.method} ${url.pathname}`;
    const failure = fail.get(key);
    if (failure !== undefined) {
      fail.delete(key);
      return json({ message: "fake failure" }, failure);
    }

    if (url.hostname === "api.test") {
      if (request.method === "POST" && url.pathname === "/v2/sandboxes") {
        const payload = asRecord(JSON.parse(new TextDecoder().decode(body ?? new Uint8Array())));
        const sandboxID = `sbx-${nextSandbox++}`;
        const sandbox: FakeSandbox = {
          sandboxID,
          envdAccessToken: `envd-${sandboxID}`,
          domain: "https://sandbox.test/",
          templateID: typeof payload.templateID === "string" ? payload.templateID : "base",
          startedAt: "2026-10-18T00:00:00.000Z",
          state: "running",
          metadata: stringRecord(payload.metadata),
          files: new Map(),
        };
        sandboxes.set(sandboxID, sandbox);
        return json({ ...sandbox, cpuCount: 2, memoryMB: 512, diskSizeMB: 10240, endAt: "2026-10-18T01:00:00.000Z" }, 201);
      }

      const sandboxMatch = /^\/sandboxes\/([^/]+)(?:\/(pause|resume|snapshots))?$/u.exec(url.pathname);
      if (sandboxMatch !== null) {
        const sandbox = sandboxes.get(decodeURIComponent(sandboxMatch[1] ?? ""));
        if (sandbox === undefined) return json({ message: "not found" }, 404);
        const action = sandboxMatch[2];
        if (request.method === "GET" && action === undefined) return sandboxJson(sandbox);
        if (request.method === "DELETE" && action === undefined) {
          sandboxes.delete(sandbox.sandboxID);
          return new Response(null, { status: 204 });
        }
        if (request.method === "POST" && action === "pause") {
          sandbox.state = "paused";
          return new Response(null, { status: 204 });
        }
        if (request.method === "POST" && action === "resume") {
          sandbox.state = "running";
          return json({ ...sandbox, cpuCount: 2, memoryMB: 512, diskSizeMB: 10240 }, 201);
        }
        if (request.method === "POST" && action === "snapshots") {
          const snapshotID = `snapshot-${nextSnapshot++}`;
          snapshots.add(snapshotID);
          return json({ snapshotID, names: [snapshotID] }, 201);
        }
      }

      const templateMatch = /^\/templates\/([^/]+)$/u.exec(url.pathname);
      if (templateMatch !== null && request.method === "DELETE") {
        snapshots.delete(decodeURIComponent(templateMatch[1] ?? ""));
        return new Response(null, { status: 204 });
      }
      return json({ message: "not found" }, 404);
    }

    if (url.hostname === "sandbox.test") {
      const sandboxId = request.headers.get("e2b-sandbox-id");
      const sandbox = sandboxId === null ? undefined : sandboxes.get(sandboxId);
      if (sandbox === undefined) return json({ message: "missing sandbox" }, 502);
      if (request.headers.get("x-access-token") !== sandbox.envdAccessToken) return json({ message: "unauthorized" }, 401);
      if (url.pathname === "/process.Process/Start" && request.method === "POST") {
        return framedResponse([
          { message: { event: { data: { stdout: base64("ok\n") } } } },
          { message: { event: { end: { exitCode: 0, exited: true } } } },
          { message: {}, flags: 2 },
        ]);
      }
      if (url.pathname === "/filesystem.Filesystem/ListDir" && request.method === "POST") {
        return json({ entries: [{ name: "hello.txt", path: "/tmp/hello.txt", type: "FILE_TYPE_FILE" }] });
      }
      if (url.pathname === "/files" && request.method === "GET") {
        const path = url.searchParams.get("path") ?? "";
        const content = sandbox.files.get(path) ?? encoder.encode("hello");
        return new Response(content, { status: 200, headers: { "content-length": String(content.length) } });
      }
      if (url.pathname === "/files" && request.method === "POST") {
        const path = url.searchParams.get("path") ?? "";
        sandbox.files.set(path, body ?? new Uint8Array());
        return json([{ name: path.split("/").at(-1) ?? path, path, type: "file" }]);
      }
      return json({ message: "not found" }, 404);
    }
    return json({ message: "not found" }, 404);
  };

  const asRecord = (value: unknown): Record<string, unknown> =>
    typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value)) : {};
  const stringRecord = (value: unknown): Record<string, string> =>
    Object.fromEntries(Object.entries(asRecord(value)).filter((entry): entry is [string, string] => typeof entry[1] === "string"));

  const sandboxJson = (sandbox: FakeSandbox) =>
    json({ ...sandbox, cpuCount: 2, memoryMB: 512, diskSizeMB: 10240, endAt: "2026-10-18T01:00:00.000Z" });

  return {
    fetch,
    calls,
    sandboxes,
    snapshots,
    fail(method: string, pathname: string, status: number) {
      fail.set(`${method} ${pathname}`, status);
    },
  };
}
