// Drive the custom-domain publication flow end to end with the real
// repository (DATABASE_URL) and the real Freestyle provider (FREESTYLE_API_KEY),
// exactly as the CLI's socket calls reach it. Run one step at a time from
// web/, adding the printed DNS records between `verify` runs:
//
//   SMOKE_ZONE=cmux.example.com bun --env-file=/dev/null run scripts/vm-publication-custom-domain-smoke.ts verify
//   ... add the records, then run `verify` again until the zone is verified ...
//   SMOKE_ZONE=... SMOKE_HOSTNAME=cmux.example.com bun ... publish     # throwaway VM + listener, public
//   SMOKE_ZONE=... SMOKE_HOSTNAME=... bun ... protect                  # personal -> fetch -> public
//   SMOKE_ZONE=... bun ... list
//   SMOKE_ZONE=... bun ... cleanup                                     # publications, forward-auth, VM
//
// Keys are read from the environment and never printed. DNS records are left
// in place; nothing else survives `cleanup`.
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import * as Effect from "effect/Effect";
import { Freestyle } from "freestyle";
import postgres from "postgres";

import {
  createPublication,
  deletePublication,
  listCustomDomains,
  listPublications,
  runVmPublicationWorkflow,
  updatePublicationAccess,
  verifyCustomDomain,
  verifyPublication,
  type PublicationPrincipal,
} from "../services/vm-publications/workflows";

const step = process.argv[2] ?? "verify";
const zone = process.env.SMOKE_ZONE?.trim();
if (!zone) throw new Error("SMOKE_ZONE is required");
const hostname = process.env.SMOKE_HOSTNAME?.trim() || zone;
const principal: PublicationPrincipal = { userId: process.env.SMOKE_OWNER?.trim() || "smoke-owner", teamIds: [] };
const forwardAuth = {
  url: "https://cmux.com/api/freestyle/forward-auth",
  serviceToken: process.env.CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET?.trim() || `smoke-forward-auth-${"x".repeat(40)}`,
};
const stateFile = process.env.SMOKE_STATE?.trim() || `/tmp/cmux-custom-domain-smoke-${zone}.json`;
const databaseUrl = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
if (!databaseUrl) throw new Error("DATABASE_URL is required");
if (!process.env.FREESTYLE_API_KEY?.trim()) throw new Error("FREESTYLE_API_KEY is required");

const log = (label: string, detail: unknown) => console.log(`[flow] ${label}: ${JSON.stringify(detail)}`);
const run = <A>(program: Parameters<typeof runVmPublicationWorkflow<A, unknown>>[0]) => runVmPublicationWorkflow(program);
const sql = postgres(databaseUrl, { max: 2 });
const client = new Freestyle({ apiKey: process.env.FREESTYLE_API_KEY.trim() });
const readState = (): { vmId?: string } => existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, "utf8")) : {};
const writeState = (state: { vmId?: string }) => writeFileSync(stateFile, JSON.stringify(state));

function printDns(records: readonly { purpose: string; recordTypes: readonly string[]; name: string; value: string }[] | null) {
  if (!records) return;
  for (const record of records) {
    console.log(`  ${record.purpose.padEnd(12)} ${record.recordTypes.join("/").padEnd(28)} ${record.name.padEnd(50)} ${record.value}`);
  }
}

async function fetchStatus(url: string, attempts = 4): Promise<{ status: number | null; detail: string }> {
  let detail = "";
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const response = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(30_000) });
      const body = (await response.text()).replace(/\s+/g, " ").slice(0, 60);
      return { status: response.status, detail: `${response.headers.get("server") ?? ""} ${body}`.trim() };
    } catch (error) {
      detail = String((error as Error).cause ?? error).slice(0, 160);
      await new Promise((resolve) => setTimeout(resolve, 5_000));
    }
  }
  return { status: null, detail };
}

async function ensureVm(): Promise<string> {
  const state = readState();
  if (state.vmId) return state.vmId;
  const created = await client.vms.create({
    displayName: `cmux-custom-domain-smoke-${zone}`,
    firewall: { rules: [] },
    idleTimeoutSeconds: 1_800,
  });
  const listener = await created.vm.exec(
    "nohup python3 -m http.server 3000 --bind 0.0.0.0 >/tmp/smoke-http.log 2>&1 & sleep 1; ss -ltn | grep -c 3000",
  );
  log("vm created", { vmId: created.vmId, listening: listener.stdout?.trim() });
  await sql`
    insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status, created_at, updated_at)
    values (${principal.userId}, 'freestyle', ${created.vmId}, 'smoke', 'running', now(), now())
  `;
  writeState({ vmId: created.vmId });
  return created.vmId;
}

try {
  switch (step) {
    case "verify": {
      const domain = await run(verifyCustomDomain({ principal, hostname: zone, forwardAuth }));
      log("verifyCustomDomain", { hostname: domain.hostname, verificationState: domain.verificationState, certificateState: domain.certificateState, publications: domain.publications });
      printDns(domain.dnsInstructions);
      break;
    }
    case "publish": {
      const vmId = await ensureVm();
      let publication = await run(createPublication({ principal, providerVmId: vmId, port: 3000, hostname, accessMode: "public", forwardAuth }));
      log("createPublication", { id: publication.id, hostname: publication.hostname, state: publication.state, verification: publication.verification?.state ?? null });
      for (let attempt = 0; attempt < 6 && publication.state !== "active"; attempt++) {
        await new Promise((resolve) => setTimeout(resolve, 10_000));
        publication = await run(verifyPublication({ principal, publicationId: hostname, forwardAuth }));
        log("verifyPublication", { state: publication.state });
      }
      log("fetch", { url: `https://${hostname}/`, ...(await fetchStatus(`https://${hostname}/`)) });
      break;
    }
    case "protect": {
      const protectedPublication = await run(updatePublicationAccess({ principal, publicationId: hostname, accessMode: "personal", forwardAuth }));
      log("updatePublicationAccess(personal)", { state: protectedPublication.state, accessMode: protectedPublication.accessMode, routingRevision: protectedPublication.routingRevision });
      log("fetch while protected (authorizer not deployed, expect fail-closed)", await fetchStatus(`https://${hostname}/`, 2));
      const reopened = await run(updatePublicationAccess({ principal, publicationId: hostname, accessMode: "public", forwardAuth }));
      log("updatePublicationAccess(public)", { state: reopened.state, accessMode: reopened.accessMode, routingRevision: reopened.routingRevision });
      log("fetch after reopening", await fetchStatus(`https://${hostname}/`));
      break;
    }
    case "list": {
      log("listCustomDomains", await run(listCustomDomains({ principal })));
      log("listPublications", (await run(listPublications({ principal }))).map((p) => ({ hostname: p.hostname, state: p.state, accessMode: p.accessMode })));
      break;
    }
    case "cleanup": {
      for (const publication of await run(listPublications({ principal }))) {
        if (publication.state === "disabled") continue;
        log("deletePublication", await run(deletePublication({ principal, publicationId: publication.hostname })));
      }
      for (const config of (await client.tls.forwardAuth.list()).configs) {
        if (config.url === forwardAuth.url) {
          await client.tls.forwardAuth.delete(config.id);
          log("deleted forward-auth config", { id: config.id });
        }
      }
      const state = readState();
      if (state.vmId) {
        await client.vms.delete(state.vmId);
        await sql`delete from cloud_vms where provider_vm_id = ${state.vmId}`;
        log("deleted vm", { vmId: state.vmId });
        rmSync(stateFile, { force: true });
      }
      break;
    }
    default:
      throw new Error(`unknown step ${step}`);
  }
} finally {
  await sql.end({ timeout: 5 });
}
