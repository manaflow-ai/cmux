import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { Freestyle } from "freestyle";
import { FreestyleProvider } from "../../services/vms/drivers/freestyle";
import type { GuestCliDistribution } from "../../services/vms/guestCliDistribution";

export type GuestExecRequest = {
  command: string;
  timeoutMs: number;
  linuxUser: string;
};

const testDistribution = (() => {
  const root = mkdtempSync(join(tmpdir(), "cmux-guest-cli-fixture-"));
  const source = join(root, "source");
  mkdirSync(source);
  const facade = "#!/bin/sh\nprintf 'synthetic facade\\n'\n";
  const core = "#!/bin/sh\nprintf 'synthetic core\\n'\n";
  writeFileSync(join(source, "cmux-cloud-cli"), facade, { mode: 0o755 });
  writeFileSync(join(source, "coderouter"), core, { mode: 0o755 });
  const archive = join(root, "cli.tar.gz");
  const tar = spawnSync("tar", ["-czf", archive, "-C", source, "cmux-cloud-cli", "coderouter"], {
    env: { ...process.env, COPYFILE_DISABLE: "1" },
  });
  if (tar.status !== 0) throw new Error("could not create the synthetic guest CLI archive");
  const digest = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
  return {
    url: pathToFileURL(archive).href,
    archiveSha256: digest(readFileSync(archive)),
    binaries: { "cmux-cloud-cli": digest(facade), coderouter: digest(core) },
  } satisfies GuestCliDistribution;
})();

/** Real pinned SDK, synthetic HTTP only. No provider credentials or network. */
export function freestyleGuestFixture(options: {
  exec?: (request: GuestExecRequest, signal?: AbortSignal | null) => Promise<Response>;
  write?: (path: string, bytes: Uint8Array, signal?: AbortSignal | null) => void | Promise<void>;
  remove?: (path: string, signal?: AbortSignal | null) => void | Promise<void>;
  deleteFailure?: boolean;
  idPrefix?: string;
  guestCliDistribution?: GuestCliDistribution;
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
        const id = `${options.idPrefix ?? "vm-fixture"}-${++allocations}`;
        liveVms.add(id);
        return Response.json({ id, state: "running", resources: { cpu: 2, memory: 8192, storage: 32768 }, vpcs: [{ ipv4: "192.0.2.10" }] });
      }
      if (url.pathname.endsWith("/fs/write")) {
        const path = url.searchParams.get("path")!;
        writes.push(path);
        await options.write?.(path, new Uint8Array(await new Response(init?.body).arrayBuffer()), signal ?? init?.signal);
        installPending = true;
        return Response.json({});
      }
      if (url.pathname.endsWith("/fs/remove")) {
        const path = url.searchParams.get("path")!;
        removals.push(path);
        await options.remove?.(path, signal ?? init?.signal);
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
      if (url.pathname.endsWith("/resize")) {
        return Response.json({ id: url.pathname.split("/").at(-2), state: "running", resources: JSON.parse(String(init?.body)) });
      }
      if (method === "DELETE" && /^\/v5\/vms\/[a-z0-9-]+-\d+$/.test(url.pathname)) {
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
    guestCliDistribution: options.guestCliDistribution ?? testDistribution,
  });
  return { provider, client, requests, writes, removals, liveVms, allocations: () => allocations };
}

export const guestCreateOptions = {
  image: "sh-synthetic",
  imageSize: { name: "md", cpu: 2, memoryMb: 8192, storageMb: 32768 },
} as const;
