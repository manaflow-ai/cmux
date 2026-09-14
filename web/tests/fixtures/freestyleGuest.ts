import { Freestyle } from "freestyle";
import { FreestyleProvider } from "../../services/vms/drivers/freestyle";

export type GuestExecRequest = {
  command: string;
  timeoutMs: number;
  linuxUser: string;
};

/** Real pinned SDK, synthetic HTTP only. No provider credentials or network. */
export function freestyleGuestFixture(options: {
  exec?: (request: GuestExecRequest, signal?: AbortSignal | null) => Promise<Response>;
  write?: (path: string, bytes: Uint8Array) => void;
  remove?: (path: string) => void;
  deleteFailure?: boolean;
} = {}) {
  const requests: Array<{ method: string; path: string }> = [];
  const writes: string[] = [];
  const removals: string[] = [];
  const liveVms = new Set<string>();
  let allocations = 0;
  let installPending = false;
  const client = (_timeoutMs?: number, signal?: AbortSignal) => new Freestyle({
    apiKey: "synthetic-test-key",
    baseUrl: "https://provider.invalid",
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      const method = init?.method ?? "GET";
      requests.push({ method, path: url.pathname });
      if (method === "POST" && url.pathname === "/v5/vms") {
        const id = `vm-fixture-${++allocations}`;
        liveVms.add(id);
        return Response.json({ id, state: "running", resources: { cpu: 2, memory: 8192, storage: 32768 }, vpcs: [{ ipv4: "192.0.2.10" }] });
      }
      if (url.pathname.endsWith("/fs/write")) {
        const path = url.searchParams.get("path")!;
        writes.push(path);
        options.write?.(path, new Uint8Array(await new Response(init?.body).arrayBuffer()));
        installPending = true;
        return Response.json({});
      }
      if (url.pathname.endsWith("/fs/remove")) {
        const path = url.searchParams.get("path")!;
        removals.push(path);
        options.remove?.(path);
        return Response.json({});
      }
      if (url.pathname.endsWith("/exec-await")) {
        const request = JSON.parse(String(init?.body)) as GuestExecRequest;
        if (installPending) {
          installPending = false;
          return options.exec?.(request, signal ?? init?.signal) ?? Response.json({ statusCode: 0 });
        }
        return Response.json({ statusCode: 0, stdout: "", stderr: "" });
      }
      if (method === "DELETE" && /^\/v5\/vms\/vm-fixture-\d+$/.test(url.pathname)) {
        if (options.deleteFailure) return Response.json({ code: "UNAVAILABLE", message: "synthetic delete failure" }, { status: 503 });
        liveVms.delete(url.pathname.split("/").at(-1)!);
        return new Response(null, { status: 204 });
      }
      throw new Error(`Unexpected synthetic provider request: ${method} ${url.pathname}`);
    }) as typeof fetch,
  });
  const provider = new FreestyleProvider({
    client,
    resolveDaemonSource: async () => { throw new Error("fixture must never resolve a live daemon"); },
  });
  return { provider, client, requests, writes, removals, liveVms, allocations: () => allocations };
}

export const guestCreateOptions = {
  image: "sh-synthetic",
  imageSize: { name: "md", cpu: 2, memoryMb: 8192, storageMb: 32768 },
} as const;
