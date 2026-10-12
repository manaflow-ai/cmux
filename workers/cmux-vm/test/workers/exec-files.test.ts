/**
 * exec and files: requests reach the exact upstream VM, responses stream
 * through without buffering, and only allowlisted fields come back.
 */
import { afterEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";

let h: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => {
  h = await makeHarness(options);
  return h;
};
afterEach(async () => {
  await h?.dispose();
  h = undefined;
});

const exec = (t: Harness, key: string, vmId: string, body: unknown) =>
  t.request(`/v1/vms/${vmId}/exec`, bearer(key), { method: "POST", body });

describe("execVm", () => {
  it("runs the command on the exact upstream VM and returns only exit code and output", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:exec"]);

    const response = await exec(t, key, vmId, { command: "echo hi", env: { GREETING: "hi" }, timeoutMs: 5000 });

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("application/json");
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ exitCode: 0, stdout: "ran: echo hi\n", stderr: "" });
    expect(text).not.toContain(upstreamId);
    expect(text).not.toContain("host-leak-check");
    expect(t.upstream.callsTo("POST", /exec-await$/).map((call) => ({ path: call.path, json: call.json }))).toEqual([
      { path: `/v5/vms/${upstreamId}/exec-await`, json: { command: "echo hi", env: { GREETING: "hi" }, timeoutMs: 5000 } },
    ]);
  });

  it("audits the exec without the command or its output", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:exec"]);

    await (await exec(t, key, vmId, { command: "echo secret-token-123" })).text();

    expect(t.audit).toEqual([expect.objectContaining({ action: "vm.exec", cmuxId: vmId, outcome: "ok" })]);
    expect(JSON.stringify(t.audit)).not.toContain("secret-token-123");
  });

  it("filters any upstream response shape down to the public fields", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:exec"]);
    t.upstream.replyToExec(
      "odd",
      () =>
        new Response(
          '{ "meta" : {"a":[1,{"b":"}\\"]"}],"c":null}, "stdout":"x\\"y\\\\z\\u00e9 \u{1F600}", "statusCode" : null,"stderr":null,"vm":"vm-123","n":-1.5e3,"t":true }',
          { headers: { "content-type": "application/json" } },
        ),
    );

    const response = await exec(t, key, vmId, { command: "odd" });
    const text = await response.text();

    expect(JSON.parse(text)).toEqual({ exitCode: null, stdout: 'x"y\\zé \u{1F600}', stderr: "" });
    expect(text).not.toContain("vm-123");
  });

  it("passes large output through intact", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:exec"]);
    const stdout = 'line "quoted" \\ back\n'.repeat(150_000);
    t.upstream.replyToExec("big", () => Response.json({ statusCode: 3, stdout, stderr: "warn" }));

    const body: unknown = await (await exec(t, key, vmId, { command: "big" })).json();

    expect(body).toEqual({ exitCode: 3, stdout, stderr: "warn" });
  });

  it("streams output before the command finishes", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:exec"]);
    const encoder = new TextEncoder();
    let finish: () => void = () => {};
    t.upstream.replyToExec("slow", () => {
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encoder.encode('{"statusCode":0,"stdout":"first part'));
          finish = () => {
            controller.enqueue(encoder.encode(' second part","stderr":""}'));
            controller.close();
          };
        },
      });
      return new Response(stream, { headers: { "content-type": "application/json" } });
    });

    const response = await exec(t, key, vmId, { command: "slow" });
    const reader = response.body?.getReader();
    if (reader === undefined) throw new Error("no body");
    const decoder = new TextDecoder();
    let seen = "";
    while (!seen.includes("first part")) {
      const chunk = await reader.read();
      if (chunk.done) throw new Error("ended early");
      seen += decoder.decode(chunk.value, { stream: true });
    }
    finish();
    for (let chunk = await reader.read(); !chunk.done; chunk = await reader.read()) seen += decoder.decode(chunk.value, { stream: true });

    expect(JSON.parse(seen)).toEqual({ exitCode: 0, stdout: "first part second part", stderr: "" });
  });

  it("answers 409 when the VM is not running", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A, "paused");
    const key = await t.addKey(TENANT_A, ["vm:exec"]);

    const response = await exec(t, key, vmId, { command: "true" });

    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ _tag: "Conflict" });
  });

  it("rejects an invalid request before calling upstream", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:exec"]);

    for (const body of [{}, { command: "" }, { command: "x", timeoutMs: 300_001 }, { command: "x", env: { "1BAD": "v" } }]) {
      expect((await exec(t, key, vmId, body)).status).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });
});

describe("files", () => {
  const content = (vmId: string, path: string) => `/v1/vms/${vmId}/files/content?path=${encodeURIComponent(path)}`;

  it("writes and reads bytes on the exact upstream VM", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:files"]);
    const bytes = Uint8Array.from({ length: 256 }, (_, index) => index);

    const written = await t.send(content(vmId, "/tmp/a.bin"), bearer(key), "PUT", bytes);
    expect(written.status).toBe(204);
    const write = t.upstream.callsTo("PUT", /fs\/write$/);
    expect(write.map((call) => [call.path, call.search.get("path")])).toEqual([[`/v5/vms/${upstreamId}/fs/write`, "/tmp/a.bin"]]);
    expect(write[0]?.bytes).toEqual(bytes);

    const read = await t.request(content(vmId, "/tmp/a.bin"), bearer(key));
    expect(read.status).toBe(200);
    expect(read.headers.get("content-type")).toBe("application/octet-stream");
    expect(read.headers.get("x-upstream-node")).toBeNull();
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(bytes);
    expect(t.audit).toEqual([expect.objectContaining({ action: "vm.files.write", cmuxId: vmId, outcome: "ok" })]);
  });

  it("serves a byte range", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:files"]);
    await t.send(content(vmId, "/tmp/r.txt"), bearer(key), "PUT", new TextEncoder().encode("0123456789"));

    const read = await t.request(content(vmId, "/tmp/r.txt"), { ...bearer(key), range: "bytes=2-5" });

    expect(read.status).toBe(206);
    expect(read.headers.get("content-range")).toBe("bytes 2-5/10");
    expect(await read.text()).toBe("2345");
  });

  it("lists a directory with only names and kinds", async () => {
    const t = await harness();
    const { vmId, upstreamId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:files"]);
    await t.send(content(vmId, "/srv/app/main.ts"), bearer(key), "PUT", new TextEncoder().encode("x"));
    await t.send(content(vmId, "/srv/readme"), bearer(key), "PUT", new TextEncoder().encode("y"));

    const response = await t.request(`/v1/vms/${vmId}/files/entries?path=${encodeURIComponent("/srv")}`, bearer(key));

    expect(response.status).toBe(200);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({
      entries: [
        { name: "app", kind: "directory" },
        { name: "readme", kind: "file" },
      ],
    });
    expect(text).not.toContain(upstreamId);
  });

  it("answers 404 for a missing file", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:files"]);

    const response = await t.request(content(vmId, "/nope"), bearer(key));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ _tag: "NotFound", message: "File not found" });
  });

  it("rejects relative and parent paths before calling upstream", async () => {
    const t = await harness();
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:files"]);

    for (const path of ["etc/passwd", "/tmp/../etc/passwd", "/tmp/a\u0000b", ""]) {
      expect((await t.request(content(vmId, path), bearer(key))).status).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("refuses an upload over the size limit with 413", async () => {
    const t = await harness({ maxUploadBytes: 8 });
    const { vmId } = t.addVm(TENANT_A);
    const key = await t.addKey(TENANT_A, ["vm:files"]);

    const response = await t.send(content(vmId, "/tmp/big"), bearer(key), "PUT", new Uint8Array(9));

    expect(response.status).toBe(413);
    expect(t.upstream.callsTo("PUT", /fs\/write$/)).toHaveLength(0);
  });
});
