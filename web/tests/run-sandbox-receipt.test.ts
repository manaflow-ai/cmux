import { describe, expect, test } from "bun:test";
import type { RunSnapshotRow } from "../services/runs/view";
import { toRunSnapshotView } from "../services/runs/view";
import { sandboxReceiptFor, sandboxReply, SANDBOX_REPLY_MAX_CHARS } from "../services/runs/sandbox";

// A sandboxed Run's receipt (hq#3367): what it ran, how it ended, what it cost, and whether its
// VM is gone. It never carries provider handles, lease tokens or token-shaped output.

describe("sandbox receipt", () => {
  test("the reply drops terminal escapes and token-shaped strings and keeps the tail", () => {
    expect(sandboxReply("\u001b[32mdone\u001b[0m\r\n")).toBe("done");
    expect(sandboxReply("key sk-abcdefghijklmnopqrstuvwxyz and ghp_abcdefghijklmnopqrstuvwxyz0123")).toBe("key [redacted] and [redacted]");
    expect(sandboxReply("   ")).toBeNull();
    const long = sandboxReply(`${"a".repeat(SANDBOX_REPLY_MAX_CHARS)}END`);
    expect(long?.endsWith("END")).toBe(true);
    expect(long?.length).toBe(SANDBOX_REPLY_MAX_CHARS + 1);
  });

  const createdAt = new Date("2026-10-25T10:00:00.000Z");
  const startedAt = new Date("2026-10-25T10:00:30.000Z");
  const finishedAt = new Date("2026-10-25T10:02:00.000Z");

  function snapshot(overrides: { status?: string; environment?: string; providerVmId?: string | null } = {}): RunSnapshotRow {
    return {
      run: {
        id: "run-1",
        userId: "user-1",
        billingTeamId: "team-1",
        idempotencyKey: "key",
        requestDigest: "sha256:x",
        source: {},
        recipe: "sandbox-task",
        provider: "cloud-vm",
        desiredAttempts: 1,
        environment: overrides.environment ?? "sandboxed",
        imageId: "sh-08be343bf2b54b4bb0e5226b97eaa6c4",
        imageVersion: "freestyle-cmux-devbox-20260902a",
        receipt: { reply: "hello", exitCode: 0, signal: null, timedOut: false, bootMs: 30_000 },
        status: overrides.status ?? "succeeded",
        cancelRequestedAt: null,
        completedAt: finishedAt,
        error: null,
        createdAt,
        updatedAt: finishedAt,
      },
      attempts: [{
        id: "attempt-1",
        runId: "run-1",
        runtimeId: null,
        ordinal: 0,
        status: "succeeded",
        providerVmId: overrides.providerVmId === undefined ? null : overrides.providerVmId,
        providerWorkspaceId: null,
        providerTerminalId: null,
        terminalRetainUntil: null,
        attachTicketHash: null,
        attachTicketExpiresAt: null,
        attachTicketConsumedAt: null,
        cleanupLeaseToken: null,
        cleanupLeaseExpiresAt: null,
        leaseToken: "lease-token-secret",
        leaseGeneration: 1,
        leaseExpiresAt: null,
        sourceDigest: null,
        result: null,
        exitCode: null,
        error: null,
        startedAt,
        finishedAt,
        createdAt,
        updatedAt: finishedAt,
      }],
      artifacts: [],
    } as RunSnapshotRow;
  }

  test("a finished sandboxed run has a receipt with status, reply, timings, cost and cleanup", () => {
    const receipt = sandboxReceiptFor(snapshot());
    expect(receipt).toMatchObject({
      schema: "cmux.run.receipt/v1",
      runId: "run-1",
      environment: "sandboxed",
      status: "succeeded",
      image: { id: "sh-08be343bf2b54b4bb0e5226b97eaa6c4", version: "freestyle-cmux-devbox-20260902a" },
      exitCode: 0,
      reply: "hello",
      timings: { bootMs: 30_000, runMs: 90_000, totalMs: 120_000 },
      cost: { vmSeconds: 120 },
      cleanup: "destroyed",
    });
  });

  test("cleanup reads pending while an attempt still holds a VM or a VM row is still up", () => {
    expect(sandboxReceiptFor(snapshot({ providerVmId: "vm-1" }))?.cleanup).toBe("pending");
    expect(sandboxReceiptFor({ ...snapshot(), sandboxVmLive: true })?.cleanup).toBe("pending");
  });

  test("the served receipt redacts a stored reply and error even if the writer did not", () => {
    const base = snapshot({ providerVmId: "vm-handle-1234" });
    const leaky = {
      ...base,
      run: { ...base.run, receipt: { reply: 'key sk-abcdefghijklmnopqrstuvwxyz on vm-handle-1234 {"password": "p"} \u001b[31mred\u001b[0m', exitCode: 1, signal: null, timedOut: false, bootMs: 1 } },
      attempts: [{ ...base.attempts[0]!, error: "auth failed: token=abcdefgh12345678 on vm-handle-1234" }],
    } as RunSnapshotRow;
    const receipt = sandboxReceiptFor(leaky);
    expect(receipt?.reply).toBe('key [redacted] on [redacted] {"password": [redacted]} red');
    expect(receipt?.error).toBe("auth failed: token=[redacted] on [redacted]");
  });

  test("secret-named keys are redacted in every quoting form", () => {
    expect(sandboxReply("password: hunter2")).toBe("password: [redacted]");
    expect(sandboxReply('PASSWORD="hunter2hunter2"')).toBe("PASSWORD=[redacted]");
    expect(sandboxReply("export MY_API_KEY=abc123def")).toBe("export MY_API_KEY=[redacted]");
    expect(sandboxReply('{"clientSecret": "s3cr3t", "name": "ok"}')).toBe('{"clientSecret": [redacted], "name": "ok"}');
    expect(sandboxReply("Authorization: Bearer abcdefghijklmnop")).not.toContain("abcdefghijklmnop");
    expect(sandboxReply("DATABASE_URL=postgres://u:p@db.internal/x")).not.toContain("u:p");
    expect(sandboxReply("curl -H 'Authorization: Basic dXNlcjpwYXNzd29yZA=='")).not.toContain("dXNlcjpwYXNzd29yZA");
    expect(sandboxReply("open postgres://admin:hunter2@db.internal/x")).toBe("open postgres://[redacted]db.internal/x");
    for (const token of [
      "glpat-abcdefghijklmnopqrst", `npm_${"a".repeat(36)}`, `hf_${"b".repeat(34)}`, `AIza${"c".repeat(35)}`, "sk_live_abcdefghijkl",
      `sntrys_${"d".repeat(40)}`, `dckr_pat_${"e".repeat(27)}`, `pypi-${"f".repeat(40)}`, `shpat_${"0".repeat(32)}`,
      `lin_api_${"g".repeat(40)}`, `dop_v1_${"1".repeat(64)}`, `hvs.${"h".repeat(24)}`, `glsa_${"i".repeat(32)}`,
      `key-${"a1".repeat(16)}`, `dapi${"b2".repeat(16)}`,
      `re_${"A1b2".repeat(8)}`, `gsk_${"c".repeat(48)}`, `xai-${"d".repeat(40)}`, `ya29.${"e".repeat(40)}`,
    ]) {
      expect(sandboxReply(`token ${token} end`)).toBe("token [redacted] end");
    }
    expect(sandboxReply("on vm1 now", ["vm1"])).toBe("on [redacted] now");
    // Ordinary words that share a prefix stay.
    expect(sandboxReply("use a key-management-service and npm_install docs")).toBe("use a key-management-service and npm_install docs");
    // After `_`, which `\b` never matches after.
    expect(sandboxReply("dump_sk-abcdefghijklmnopqrstuvwxyz.txt")).toBe("dump_[redacted].txt");
    expect(sandboxReply("dump_ghp_abcdefghijklmnopqrstuvwxyz0123.txt")).toBe("dump_[redacted].txt");
  });

  test("VM time runs from the attempt's start plus its boot, not from the Run's queueing", () => {
    // createdAt 10:00:00, startedAt 10:00:30, finishedAt 10:02:00, boot 30 s: 90 s run + 30 s boot.
    expect(sandboxReceiptFor(snapshot())?.cost.vmSeconds).toBe(120);
    const queued = snapshot();
    const late = { ...queued, run: { ...queued.run, createdAt: new Date("2026-10-25T09:00:00.000Z") } } as RunSnapshotRow;
    expect(sandboxReceiptFor(late)?.cost.vmSeconds).toBe(120);
  });

  test("an artifact media type is a bare type/subtype or octet-stream", () => {
    const base = snapshot();
    const artifact = (mediaType: string) => ({ id: "a1", runId: "run-1", attemptId: "attempt-1", name: "out.txt", mediaType, sizeBytes: 3, digest: `sha256:${"a".repeat(64)}`, uri: "x", metadata: {}, createdAt, writerLeaseGeneration: null, writerLeaseTokenHash: null });
    const types = (mediaType: string) => sandboxReceiptFor({ ...base, artifacts: [artifact(mediaType)] } as RunSnapshotRow)?.artifacts[0]?.mediaType;
    expect(types("text/markdown")).toBe("text/markdown");
    expect(types("text/plain; token=abcdefgh12345678")).toBe("application/octet-stream");
    expect(types("text/sk-abcdefghijklmnopqrstuvwxyz")).toBe("application/octet-stream");
  });

  test("a private key block in the output is redacted whole", async () => {
    const { generateKeyPairSync, createPrivateKey } = await import("node:crypto");
    const pem = generateKeyPairSync("ed25519").privateKey.export({ format: "pem", type: "pkcs8" }).toString();
    const reply = sandboxReply(`cat key.pem\n${pem}done`);
    expect(reply).toBe("cat key.pem\n[redacted private key]\ndone");
    expect(() => createPrivateKey(reply ?? "")).toThrow();
    expect(sandboxReply("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n(cut off)")).toBe("[redacted private key]");
  });

  test("a sandboxed snapshot's artifacts list is redacted like the receipt's; a persistent one is untouched", () => {
    const base = snapshot();
    const artifact = { id: "a1", runId: "run-1", attemptId: "attempt-1", name: "dump_sk-abcdefghijklmnopqrstuvwxyz.txt", mediaType: "text/plain", sizeBytes: 3, digest: `sha256:${"a".repeat(64)}`, uri: "runs/run-1/dump_sk-abcdefghijklmnopqrstuvwxyz.txt", metadata: {}, createdAt, writerLeaseGeneration: null, writerLeaseTokenHash: null };
    const sandboxed = toRunSnapshotView({ ...base, artifacts: [artifact] } as RunSnapshotRow);
    expect(JSON.stringify(sandboxed)).not.toContain("sk-abcdefghijklmnopqrstuvwxyz");
    expect(sandboxed.artifacts[0]).toMatchObject({ name: "dump_[redacted].txt", uri: "runs/run-1/dump_[redacted].txt" });
    const persistent = toRunSnapshotView({ ...base, run: { ...base.run, environment: "persistent" }, artifacts: [artifact] } as RunSnapshotRow);
    expect(persistent.artifacts[0]?.name).toBe(artifact.name);
  });

  test("an artifact name is redacted like the reply", () => {
    const base = snapshot();
    const artifact = { id: "a1", runId: "run-1", attemptId: "attempt-1", name: "dump-sk-abcdefghijklmnopqrstuv.txt", mediaType: "text/plain", sizeBytes: 3, digest: `sha256:${"a".repeat(64)}`, uri: "x", metadata: {}, createdAt, writerLeaseGeneration: null, writerLeaseTokenHash: null };
    const withArtifact = { ...base, artifacts: [artifact] } as RunSnapshotRow;
    expect(sandboxReceiptFor(withArtifact)?.artifacts[0]?.name).toBe("dump-[redacted].txt");
  });

  test("a VM lifetime nobody measured is a null cost, never zero", () => {
    const base = snapshot();
    const noStart = { ...base.attempts[0]!, startedAt: null };
    const lost = { ...base, run: { ...base.run, receipt: null }, attempts: [noStart] } as RunSnapshotRow;
    expect(sandboxReceiptFor(lost)?.cost).toMatchObject({ vmSeconds: null, estimateUsd: null });
    const createFailed = { ...base, run: { ...base.run, receipt: { reply: null, exitCode: null, signal: null, timedOut: false, bootMs: null } }, attempts: [noStart] } as RunSnapshotRow;
    expect(sandboxReceiptFor(createFailed)?.cost).toMatchObject({ vmSeconds: null, estimateUsd: null });
  });

  test("a running or persistent run has no receipt", () => {
    expect(sandboxReceiptFor(snapshot({ status: "running" }))).toBeNull();
    expect(sandboxReceiptFor(snapshot({ environment: "persistent" }))).toBeNull();
  });

  test("the public snapshot carries the receipt and the pinned image, never provider handles or leases", () => {
    const view = toRunSnapshotView(snapshot({ providerVmId: "vm-private-handle" }));
    expect(view.run.environment).toBe("sandboxed");
    expect(view.run.image).toEqual({ id: "sh-08be343bf2b54b4bb0e5226b97eaa6c4", version: "freestyle-cmux-devbox-20260902a" });
    expect(view.receipt?.status).toBe("succeeded");
    const text = JSON.stringify(view);
    expect(text).not.toContain("vm-private-handle");
    expect(text).not.toContain("lease-token-secret");
  });
});

describe("the sandbox VM key namespace", () => {
  test("no request may name a sandbox-run idempotency key", async () => {
    const { idempotencyKeyFromRequest } = await import("../services/vms/routeInput");
    const refused = idempotencyKeyFromRequest(new Request("https://cmux.test", { headers: { "idempotency-key": "sandbox-run:run-1:attempt:a-1" } }));
    expect(refused.ok).toBe(false);
    if (!refused.ok) expect(await refused.response.json()).toMatchObject({ error: "vm_idempotency_key_reserved" });
    expect(idempotencyKeyFromRequest(new Request("https://cmux.test", { headers: { "idempotency-key": "my-key" } }))).toEqual({ ok: true, key: "my-key" });
  });
});
