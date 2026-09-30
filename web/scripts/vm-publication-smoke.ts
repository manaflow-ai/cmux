// Live smoke for Cloud VM publications against the Freestyle account that
// owns the generated zone (cmux.sh). Run from web/ with the account's key in
// the environment; the key is never printed:
//
//   FREESTYLE_API_KEY=... bun --env-file=/dev/null run scripts/vm-publication-smoke.ts
//   FREESTYLE_API_KEY=... SMOKE_MUTATE=1 bun --env-file=/dev/null run scripts/vm-publication-smoke.ts
//
// Without SMOKE_MUTATE=1 it is read-only: zone ownership, the wildcard
// certificate, rule pagination, and the provider's certificate resolution.
// With it, every mutation is uniquely named and cleaned up in reverse order:
// a verification challenge (to observe the incomplete-proof error), a
// forward-auth config, a throwaway VM with a listener on port 3000, and a
// TLS rule for a generated hostname that is fetched over HTTPS.
import { Freestyle, FreestyleApiError } from "freestyle";
import * as Effect from "effect/Effect";
import { makeVmPublicationProvider } from "../services/vm-publications/provider";
import { friendlyPublicationLabel } from "../services/vm-publications/friendlyNames";

const rand = Math.random().toString(16).slice(2, 8);
const log = (step: string, detail: unknown) =>
  console.log(`[smoke] ${step}: ${JSON.stringify(detail)}`);
const errorDetail = (error: unknown) =>
  error instanceof FreestyleApiError
    ? { status: error.status, code: error.code, message: error.message.slice(0, 200) }
    : { message: String(error).slice(0, 200) };

const apiKey = process.env.FREESTYLE_API_KEY?.trim();
if (!apiKey) throw new Error("FREESTYLE_API_KEY is required");
const client = new Freestyle({ apiKey });
const provider = makeVmPublicationProvider(() => client);
const run = <A>(effect: Effect.Effect<A, unknown>) => Effect.runPromise(effect as Effect.Effect<A, never>);

// ---------------- phase 1: read-only ----------------
const domains = await client.domains.list();
log("domains.list", { count: domains.length, hasCmuxSh: domains.some((d) => d.domain === "cmux.sh"), sample: domains.slice(0, 5).map((d) => d.domain) });

const certificates = await client.domains.certificates.list();
const wildcard = certificates.find((c) => c.domain === "cmux.sh" && c.wildcard);
log("certificates.list", { count: certificates.length, cmuxShWildcard: wildcard ?? null });

const page1 = await client.tls.rules.list({ limit: 2, offset: 0 });
const page2 = await client.tls.rules.list({ limit: 2, offset: 2 });
log("tls.rules.list pagination", {
  totalCount: page1.totalCount,
  page1: page1.rules.map((r) => r.id),
  page2: page2.rules.map((r) => r.id),
  overlap: page1.rules.some((r) => page2.rules.some((s) => s.id === r.id)),
});

const forwardAuths = await client.tls.forwardAuth.list();
log("tls.forwardAuth.list", {
  totalCount: forwardAuths.totalCount,
  urls: forwardAuths.configs.map((c) => c.url),
});

const vms = await client.vms.list();
log("vms.list", { count: vms.vms?.length ?? (vms as unknown as unknown[]).length ?? null });

log("provider.getWildcardCertificateStatus(cmux.sh)", await run(provider.getWildcardCertificateStatus("cmux.sh")));
log("provider.getCertificateStatus(generated name)", await run(provider.getCertificateStatus(`${friendlyPublicationLabel()}.cmux.sh`)));

if (process.env.SMOKE_MUTATE !== "1") {
  log("done", { mutations: "skipped (SMOKE_MUTATE!=1)" });
  process.exit(0);
}

// ---------------- phase 2: mutations with cleanup ----------------
const cleanup: Array<() => Promise<void>> = [];
try {
  // (a) What does completion return before the TXT proof exists?
  const probeDomain = `cmux-smoke-${rand}.example.org`;
  const verification = await client.domains.verifications.create(probeDomain);
  cleanup.push(async () => {
    await client.domains.verifications.delete(verification.id);
    log("cleanup", { withdrewVerification: verification.id });
  });
  log("verifications.create", { id: verification.id, domain: verification.domain, state: verification.state, recordName: verification.recordName });
  try {
    const completed = await client.domains.verifications.complete(verification.id);
    log("verifications.complete (unexpected success)", completed);
  } catch (error) {
    log("verifications.complete error (proof missing)", errorDetail(error));
  }
  log("provider.completeDomainVerification (proof missing)", await run(provider.completeDomainVerification(verification.id)));

  // (b) Forward-auth singleton create/adopt/delete through the provider.
  const smokeAuthUrl = `https://cmux.com/api/freestyle/forward-auth-smoke-${rand}`;
  const ensured = await run(provider.ensureSharedForwardAuth({
    existingForwardAuthId: null,
    url: smokeAuthUrl,
    serviceToken: `smoke-${rand}-${"x".repeat(32)}`,
  }));
  cleanup.push(async () => {
    await client.tls.forwardAuth.delete(ensured.forwardAuthId);
    log("cleanup", { deletedForwardAuth: ensured.forwardAuthId });
  });
  log("provider.ensureSharedForwardAuth", ensured);
  const adopted = await run(provider.ensureSharedForwardAuth({
    existingForwardAuthId: null,
    url: smokeAuthUrl,
    serviceToken: `smoke-${rand}-${"y".repeat(32)}`,
  }));
  log("provider.ensureSharedForwardAuth (adopt existing by url)", { ...adopted, sameId: adopted.forwardAuthId === ensured.forwardAuthId });

  // (c) A generated hostname routed to a throwaway VM, served over TLS, then swept.
  const created = await client.vms.create({
    displayName: `cmux-smoke-${rand}`,
    firewall: { rules: [] },
    idleTimeoutSeconds: 120,
  });
  const vmId = created.vmId;
  cleanup.push(async () => {
    await client.vms.delete(vmId);
    log("cleanup", { deletedVm: vmId });
  });
  log("vms.create", { vmId });
  const python = await created.vm.exec("command -v python3 || echo missing");
  log("vm python3", { stdout: python.stdout?.trim() });
  const started = await created.vm.exec(
    "nohup python3 -m http.server 3000 --bind 0.0.0.0 >/tmp/smoke-http.log 2>&1 & sleep 1; ss -ltn | grep 3000 || netstat -ltn | grep 3000 || echo not-listening",
  );
  log("vm listener", { stdout: started.stdout?.trim().slice(0, 200), stderr: started.stderr?.trim().slice(0, 200) });

  const hostname = `cmux-smoke-${friendlyPublicationLabel()}.cmux.sh`;
  const reconciled = await run(provider.reconcileTlsRule(null, { hostname, providerVmId: vmId, port: 3000 }));
  cleanup.push(async () => {
    const swept = await run(provider.deleteTlsRulesForHostnames([hostname]));
    const remaining = (await client.tls.rules.list({ limit: 100 })).rules.filter((r) => r.domain === hostname).length;
    log("cleanup", { sweptRules: swept, remainingForHostname: remaining });
  });
  log("provider.reconcileTlsRule", reconciled);
  log("provider.reconcileTlsRule (repeat is idempotent)", await run(provider.reconcileTlsRule(reconciled.rule.tlsRuleId, { hostname, providerVmId: vmId, port: 3000 })));
  log("provider.getCertificateStatus(hostname)", await run(provider.getCertificateStatus(hostname)));

  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const response = await fetch(`https://${hostname}/`, { redirect: "manual", signal: AbortSignal.timeout(5_000) });
      const body = (await response.text()).slice(0, 80);
      log(`https fetch attempt ${attempt}`, { status: response.status, server: response.headers.get("server"), body });
      break;
    } catch (error) {
      log(`https fetch attempt ${attempt} failed`, { message: String((error as Error).cause ?? error).slice(0, 200) });
      await new Promise((resolve) => setTimeout(resolve, 2_000));
    }
  }
} finally {
  for (const step of cleanup.reverse()) {
    try {
      await step();
    } catch (error) {
      log("cleanup failed", errorDetail(error));
    }
  }
}
log("done", { mutations: "completed" });
