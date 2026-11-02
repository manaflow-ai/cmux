import { describe, expect, test } from "bun:test";
import type { RunSnapshotRow } from "../services/runs/view";
import { toRunEventView, toRunSnapshotView } from "../services/runs/view";
import { redactReceiptValue, SANDBOX_SCRUBBED_FROM_KEY, sandboxPayloadDigest, sandboxReceiptFor, sandboxReply, sandboxRunsAllowed, SANDBOX_REPLY_MAX_CHARS } from "../services/runs/sandbox";

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
    const vm = { createdAt: new Date("2026-10-25T10:00:00.000Z"), destroyedAt: new Date("2026-10-25T10:02:00.000Z"), live: false };
    const receipt = sandboxReceiptFor({ ...snapshot(), sandboxVms: [vm] } as RunSnapshotRow);
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

  test("the launcher's error is the receipt's error when the journal has none", () => {
    const base = snapshot();
    const failed = { ...base, run: { ...base.run, status: "failed", receipt: { reply: null, exitCode: null, signal: null, timedOut: false, bootMs: null, error: "provider refused" } } } as RunSnapshotRow;
    expect(sandboxReceiptFor(failed)?.error).toBe("provider refused");
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
    // Cut off before the closing quote (a timeout mid-line).
    expect(sandboxReply('PASSWORD="example-pass-123!')).toBe("PASSWORD=[redacted]");
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
      `sbp_${"0a".repeat(20)}`, `lsv2_pt_${"f".repeat(32)}`, `nfp_${"g".repeat(36)}`, `ATATT3x${"h".repeat(30)}`,
    ]) {
      expect(sandboxReply(`token ${token} end`)).toBe("token [redacted] end");
    }
    expect(sandboxReply("on vm1 now", ["vm1"])).toBe("on [redacted] now");
    // Cloud and registry credentials in query and connection strings.
    expect(sandboxReply("https://acct.blob.core.windows.net/c/f?sv=2022&sig=AbCdEf%2Bsecret123&se=2026")).not.toContain("AbCdEf");
    expect(sandboxReply("DefaultEndpointsProtocol=https;AccountName=a;AccountKey=c2VjcmV0a2V5MTIz==;EndpointSuffix=x")).not.toContain("c2VjcmV0a2V5MTIz");
    expect(sandboxReply("//registry.npmjs.org/:_auth=dXNlcjpwYXNz")).not.toContain("dXNlcjpwYXNz");
    // Ordinary words that share a prefix stay.
    expect(sandboxReply("use a key-management-service and npm_install docs")).toBe("use a key-management-service and npm_install docs");
    // After `_`, which `\b` never matches after.
    expect(sandboxReply("dump_sk-abcdefghijklmnopqrstuvwxyz.txt")).toBe("dump_[redacted].txt");
    expect(sandboxReply("dump_ghp_abcdefghijklmnopqrstuvwxyz0123.txt")).toBe("dump_[redacted].txt");
    expect(sandboxReply("dump_AKIA1234567890123456_backup")).toBe("dump_[redacted]_backup");
    expect(sandboxReply("cfg_postgres://admin:hunter2@db/x")).not.toContain("hunter2");
  });

  test("npm and Azure credential keys are redacted in any spacing, quoting or JSON", () => {
    for (const line of [
      "_auth = dXNlcjpwYXNz", "_auth=dXNlcjpwYXNz", '"_auth": "dXNlcjpwYXNz"', "//registry.npmjs.org/:_auth = dXNlcjpwYXNz",
      '{"AccountKey":"dXNlcjpwYXNz"}', "AccountKey = dXNlcjpwYXNz", '{"SharedAccessSignature": "dXNlcjpwYXNz"}', "account_key: dXNlcjpwYXNz",
    ]) {
      expect(sandboxReply(line)).not.toContain("dXNlcjpwYXNz");
    }
    // Only the key itself: a word that ends in `_author` is ordinary text.
    expect(sandboxReply("book_author = Jane")).toBe("book_author = Jane");
    expect(redactReceiptValue({ AccountKey: "a", _auth: "b", sig: "c", SharedAccessKey: "d", author: "Jane" }, []))
      .toEqual({ AccountKey: "[redacted]", _auth: "[redacted]", sig: "[redacted]", SharedAccessKey: "[redacted]", author: "Jane" });
  });

  test("VM time is the VM rows' own lifetime, not the Run's queueing or the attempt's run; unknown without a row", () => {
    const vm = { createdAt: new Date("2026-10-25T10:00:10.000Z"), destroyedAt: new Date("2026-10-25T10:02:10.000Z"), live: false };
    const late = snapshot();
    const queuedLong = { ...late, run: { ...late.run, createdAt: new Date("2026-10-25T09:00:00.000Z") }, sandboxVms: [vm] } as RunSnapshotRow;
    expect(sandboxReceiptFor(queuedLong)?.cost.vmSeconds).toBe(120);
    // The row is gone (or none was made): the attempt's timings say nothing about when the VM went away.
    expect(sandboxReceiptFor({ ...late, sandboxVms: [] } as RunSnapshotRow)?.cost).toMatchObject({ vmSeconds: null, estimateUsd: null });
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

  test("VM time follows the VM rows through destruction, and the cost is provisional until then", () => {
    const base = snapshot();
    const created = new Date("2026-10-25T10:00:10.000Z");
    const destroyedLate = new Date("2026-10-25T12:00:10.000Z");
    const destroyed = { ...base, sandboxVms: [{ createdAt: created, destroyedAt: destroyedLate, live: false }] } as RunSnapshotRow;
    expect(sandboxReceiptFor(destroyed)?.cost).toMatchObject({ vmSeconds: 7_200, final: true });
    const up = { ...base, sandboxVmLive: true, sandboxVms: [{ createdAt: created, destroyedAt: null, live: true }] } as RunSnapshotRow;
    expect(sandboxReceiptFor(up)?.cost.final).toBe(false);
    // No VM row at all (a create that failed before the provider made one): no accrual, final.
    const none = { ...base, sandboxVms: [] } as RunSnapshotRow;
    expect(sandboxReceiptFor(none)?.cost.final).toBe(true);
    expect(sandboxReceiptFor(up)?.cleanup).toBe("pending");
  });

  test("every string in a sandboxed artifact's metadata is redacted when served", () => {
    const base = snapshot({ providerVmId: "vm-private-handle" });
    const artifact = { id: "a1", runId: "run-1", attemptId: "attempt-1", name: "out.txt", mediaType: "text/plain", sizeBytes: 3, digest: `sha256:${"a".repeat(64)}`, uri: "x", metadata: { note: "sk-abcdefghijklmnopqrstuvwxyz", paths: ["work/vm-private-handle"], size: 3 }, createdAt, writerLeaseGeneration: null, writerLeaseTokenHash: null };
    const view = toRunSnapshotView({ ...base, artifacts: [artifact] } as RunSnapshotRow);
    expect(view.artifacts[0]?.metadata).toEqual({ note: "[redacted]", paths: ["work/[redacted]"], size: 3 });
    const keyed = { ...artifact, metadata: { "vm-private-handle": 1, token: "opaque-credential", nested: { password: "hunter2" } } };
    const keyedView = toRunSnapshotView({ ...base, artifacts: [keyed] } as RunSnapshotRow);
    // The view already drops secret-named keys (view.ts redactedRecord); what is left is redacted.
    expect(keyedView.artifacts[0]?.metadata).toEqual({ "[redacted]": 1, token: "[redacted]", nested: {} });
  });

  test("signed cloud URL signatures and a JSON sig are redacted in text and metadata", () => {
    for (const line of [
      '{"sig":"c2lnbmF0dXJlMTIz"}', "sig = c2lnbmF0dXJlMTIz",
      "https://b.s3.amazonaws.com/o?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=c2lnbmF0dXJlMTIz&X-Amz-Expires=60",
      "https://storage.googleapis.com/b/o?X-Goog-Algorithm=GOOG4-RSA-SHA256&X-Goog-Signature=c2lnbmF0dXJlMTIz",
      '{"X-Amz-Security-Token": "c2lnbmF0dXJlMTIz"}',
    ]) {
      expect(sandboxReply(line)).not.toContain("c2lnbmF0dXJlMTIz");
    }
    expect(sandboxReply("signal: 9")).toBe("signal: 9");
    // A short Basic credential (`a:b`), a YAML block value, and a token after a carriage return.
    expect(sandboxReply("Authorization: Basic YTpi")).not.toContain("YTpi");
    expect(sandboxReply("db:\n  password: |-\n    hunter2\n    more\n  host: x\n")).not.toMatch(/hunter2|more/);
    expect(sandboxReply("db:\n  password: |-\n    hunter2\n  host: x\n")).toContain("host: x");
    expect(sandboxReply("loading\rsk-abcdefghijklmnopqrstuvwxyz\n")).not.toContain("abcdefghijklmnop");
    // A kubeconfig's base64 key, cookie headers, a bare signature, a YAML block with a comment.
    expect(sandboxReply("users:\n- user:\n    client-key-data: LS0tLS1CRUdJTiBSU0E=\n")).not.toContain("LS0tLS1CRUdJTiBSU0E");
    expect(redactReceiptValue({ "client-key-data": "LS0t" }, [])).toEqual({ "client-key-data": "[redacted]" });
    expect(sandboxReply("Set-Cookie: session=abc123def; Path=/")).not.toContain("abc123def");
    expect(sandboxReply("Cookie: a=1; theme=dark")).toBe("Cookie: [redacted]");
    expect(sandboxReply("signature: c2lnbmF0dXJl")).not.toContain("c2lnbmF0dXJl");
    expect(sandboxReply("password: |- # rotated\n  hunter2\nhost: x\n")).not.toContain("hunter2");
    // Ordinary words stay.
    expect(sandboxReply("sessions: 3 open; the cookie jar tests passed")).toBe("sessions: 3 open; the cookie jar tests passed");
    // Docker's config.json keeps a reversible user:password under "auth".
    expect(sandboxReply('{"auths":{"registry.example":{"auth":"dXNlcjpwYXNz"}}}')).not.toContain("dXNlcjpwYXNz");
    expect(sandboxReply("auth: required")).toBe("auth: required");
    expect(redactReceiptValue({ auths: { "registry.example": { auth: "dXNlcjpwYXNz" } } }, [])).toEqual({ auths: { "registry.example": { auth: "[redacted]" } } });
    // A one-character value under a secret-named key is still a value.
    expect(sandboxReply("PASSWORD: x")).toBe("PASSWORD: [redacted]");
    expect(sandboxReply("sig: a")).toBe("sig: [redacted]");
    expect(redactReceiptValue({ "X-Amz-Signature": "a", signature: "b", "X-Goog-Credential": "c", note: "ok" }, []))
      .toEqual({ "X-Amz-Signature": "[redacted]", signature: "[redacted]", "X-Goog-Credential": "[redacted]", note: "ok" });
  });

  test("a sandboxed run's errors and artifact digests are served redacted; a persistent run's are untouched", () => {
    const base = snapshot({ providerVmId: "vm-secret-1" });
    const artifact = { id: "a1", runId: "run-1", attemptId: "attempt-1", name: "out.txt", mediaType: "text/plain", sizeBytes: 3, digest: "vm-secret-1", uri: "artifact://x", metadata: {}, createdAt, writerLeaseGeneration: null, writerLeaseTokenHash: null };
    const failing = {
      ...base,
      run: { ...base.run, error: "boot failed on vm-secret-1 with sk-abcdefghijklmnopqrstuv" },
      attempts: [{ ...base.attempts[0]!, error: "vm-secret-1 lost" }],
      artifacts: [artifact],
    } as RunSnapshotRow;
    const view = toRunSnapshotView(failing);
    const served = JSON.stringify({ run: view.run.error, attempt: view.attempts[0]?.error, artifacts: view.artifacts, receipt: view.receipt?.artifacts });
    expect(served).not.toContain("vm-secret-1");
    expect(served).not.toContain("abcdefghijklmnop");
    // Never attachable, even inside the launcher's handoff window.
    const handoff = toRunSnapshotView({ ...failing, attempts: [{ ...failing.attempts[0]!, providerWorkspaceId: "ws-1", providerTerminalId: "term-1", terminalRetainUntil: new Date(Date.now() + 60_000) }] } as RunSnapshotRow);
    expect(handoff.attempts[0]).toMatchObject({ attachable: false, retainedUntil: null });
    const persistent = toRunSnapshotView({ ...failing, run: { ...failing.run, environment: "persistent" } } as RunSnapshotRow);
    expect(persistent.run.error).toBe(failing.run.error);
    expect(persistent.artifacts[0]?.digest).toBe("vm-secret-1");
  });

  test("the value cleanup stores redacts secret-named values and keys at any depth", () => {
    expect(redactReceiptValue({ password: "hunter2", nested: { token: "x", "vm-1": "ok" } }, ["vm-1"]))
      .toEqual({ password: "[redacted]", nested: { token: "[redacted]", "[redacted]": "ok" } });
  });

  test("an artifact name is redacted like the reply", () => {
    const base = snapshot();
    const artifact = { id: "a1", runId: "run-1", attemptId: "attempt-1", name: "dump-sk-abcdefghijklmnopqrstuv.txt", mediaType: "text/plain", sizeBytes: 3, digest: `sha256:${"a".repeat(64)}`, uri: "x", metadata: {}, createdAt, writerLeaseGeneration: null, writerLeaseTokenHash: null };
    const withArtifact = { ...base, artifacts: [artifact] } as RunSnapshotRow;
    expect(sandboxReceiptFor(withArtifact)?.artifacts[0]?.name).toBe("dump-[redacted].txt");
  });

  test("a machine nobody recorded may exist: cleanup pending, VM time unknown", () => {
    const unknown = { ...snapshot(), sandboxVmLive: true, sandboxVmUnknown: true, sandboxVms: [] } as RunSnapshotRow;
    const receipt = sandboxReceiptFor(unknown);
    expect(receipt?.cleanup).toBe("pending");
    expect(receipt?.cost.vmSeconds).toBeNull();
  });

  test("a sandboxed Run's journal events are served redacted like its receipt; a persistent Run's are not", () => {
    const event = { id: "e1", runId: "run-1", attemptId: "attempt-1", sequence: 1, attemptSequence: 0, externalId: "out-1", kind: "attempt.output", payload: { text: "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENG", token: "abc" }, createdAt, writerLeaseGeneration: null, writerLeaseTokenHash: null } as unknown as Parameters<typeof toRunEventView>[0];
    const served = JSON.stringify(toRunEventView(event, "sandboxed"));
    expect(served).not.toContain("wJalrXUtnFEMIK7MDENG");
    expect(served).not.toContain('"abc"');
    expect(JSON.stringify(toRunEventView(event))).toContain("wJalrXUtnFEMIK7MDENG");
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

describe("sandbox journal events", () => {
  const event = (payload: Record<string, unknown>) => ({
    id: "event-1", runId: "run-1", attemptId: "attempt-1", sequence: 2, attemptSequence: 1, externalId: "output-1",
    kind: "attempt.output", payload, createdAt: new Date("2026-10-25T10:00:00.000Z"),
  }) as never;

  test("a sandboxed Run's events are served with its provider handles redacted out of text", () => {
    const view = toRunEventView(event({ text: "task ran on vm-private-0123456789" }), "sandboxed", ["vm-private-0123456789"]);
    expect(JSON.stringify(view)).not.toContain("vm-private-0123456789");
    expect(view.payload).toEqual({ text: "task ran on [redacted]" });
  });

  test("cleanup's record of what the worker sent ignores key order and is never served", () => {
    expect(sandboxPayloadDigest({ a: 1, b: { c: [1, { d: 2, e: 3 }] } })).toBe(sandboxPayloadDigest({ b: { c: [1, { e: 3, d: 2 }] }, a: 1 }));
    expect(sandboxPayloadDigest({ a: 1 })).not.toBe(sandboxPayloadDigest({ a: 2 }));
    const view = toRunEventView(event({ text: "ran on [redacted]", [SANDBOX_SCRUBBED_FROM_KEY]: sandboxPayloadDigest({ text: "ran on vm-1" }) }), "sandboxed");
    expect(view.payload).toEqual({ text: "ran on [redacted]" });
  });
});

describe("sandbox preview gate", () => {
  test("local dev allows everyone; a deployment allows only the accounts it names", () => {
    expect(sandboxRunsAllowed("user-1", {})).toBe(true);
    expect(sandboxRunsAllowed("user-1", { VERCEL: "1" })).toBe(false);
    expect(sandboxRunsAllowed("user-1", { VERCEL: "1", CMUX_RUN_SANDBOX_USER_IDS: "" })).toBe(false);
    expect(sandboxRunsAllowed("user-1", { VERCEL: "1", CMUX_RUN_SANDBOX_USER_IDS: "user-2, user-1" })).toBe(true);
    expect(sandboxRunsAllowed("user-1", { VERCEL_ENV: "production", CMUX_RUN_SANDBOX_USER_IDS: "user-2" })).toBe(false);
    expect(sandboxRunsAllowed("user-1", { VERCEL: "1", CMUX_RUN_SANDBOX_USER_IDS: "*" })).toBe(true);
  });
});
