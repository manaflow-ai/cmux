#!/usr/bin/env bun
/**
 * Throwaway in-guest metadata probe (issue #13070, stream 5 step 0).
 *
 *   FREESTYLE_API_KEY=… bun scripts/cloud-vm/probe-metadata.ts [--image sh-…] [--out-dir /tmp/13070-nm]
 *
 * Creates one machine from the manifest's md desktop default with a
 * `cmux-vm-name` metadata entry, runs the metadata-service token dance the
 * supervisor uses (cmux-devbox-boot `instance_id()`) against every plausible
 * path, then `vm.update({ metadata })` and re-reads, and deletes the machine
 * before exit, including on failure. The answer decides whether the prompt
 * name can be delivered through create metadata (readable in the guest) or
 * must be written by a create-time exec.
 *
 * Writes <out-dir>/metadata-probe.json and <out-dir>/metadata-probe.md.
 */
import { Freestyle, type Vm } from "freestyle";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { freestyleFirewallRules } from "../../services/vms/drivers/freestyle";
import { resolveVmImage } from "../../services/vms/images/resolver";
import { vmImageSize } from "../../services/vms/images/sizes";
import { pollBoundedFetch, providerCredentialsFromEnv } from "./benchStats.mjs";

const args = process.argv.slice(2);
const option = (flag: string): string | undefined => {
  const at = args.indexOf(flag);
  return at === -1 ? undefined : args[at + 1];
};
const outDir = option("--out-dir") ?? "/tmp/13070-nm";
const size = vmImageSize("md");
const image = option("--image") ?? resolveVmImage("freestyle", undefined, process.env, { kind: "desktop", memoryMb: size.memoryMb }).image;
const PROBE_VALUE = "probe-name";
const RENAMED_VALUE = "renamed";
const METADATA_KEY = "cmux-vm-name";

const credentials = providerCredentialsFromEnv();
if (!credentials) {
  console.error("probe-metadata: FREESTYLE_API_KEY (or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID) is required; source ~/.secrets/cmux.env");
  process.exit(2);
}
const polling = pollBoundedFetch({ fetchTimeoutMs: 120_000, pollDeadlineMs: 10 * 60 * 1000 });
const fs = new Freestyle({ ...credentials, fetch: polling.fetch });

function bounded<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${ms} ms`)), ms);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

const PATHS = [
  "/",
  "/latest/",
  "/latest/meta-data/",
  "/latest/meta-data/instance-id",
  "/latest/meta-data/tags/",
  "/latest/meta-data/tags/instance/",
  `/latest/meta-data/tags/instance/${METADATA_KEY}`,
  `/latest/meta-data/${METADATA_KEY}`,
  "/latest/meta-data/metadata",
  "/latest/meta-data/metadata/",
  `/latest/meta-data/metadata/${METADATA_KEY}`,
  "/latest/user-data",
  "/latest/dynamic/instance-identity/document",
  "/latest/dynamic/",
  "/metadata",
  "/metadata/",
  `/metadata/${METADATA_KEY}`,
  `/${METADATA_KEY}`,
  "/latest/meta-data/hostname",
  "/latest/meta-data/local-hostname",
  "/latest/meta-data/local-ipv4",
  "/openstack/latest/meta_data.json",
  "/freestyle/",
  "/latest/freestyle/",
];

/**
 * One exec that performs the token dance once and curls every path with the
 * token (the supervisor's header), then the root with an Accept: JSON header
 * (Firecracker MMDS returns the whole store as JSON that way), then two
 * no-token GETs (MMDS v1 style). Every body is delimited so a body containing
 * newlines survives parsing.
 */
function probeScript(): string {
  const paths = PATHS.map((p) => `'${p}'`).join(" ");
  return [
    "M=http://169.254.169.254",
    "T=$(curl -sf -m 2 -X PUT \"$M/latest/api/token\" -H 'X-metadata-token-ttl-seconds: 60') || T=''",
    "printf '@@TOKEN %s\\n' \"$([ -n \"$T\" ] && echo 1 || echo 0)\"",
    "probe() { printf '@@PATH %s\\n' \"$1\"; shift; curl -s -m 2 -o - -w '\\n@@STATUS %{http_code}' \"$@\" 2>&1 | head -c 4000; printf '\\n@@END\\n'; }",
    `for p in ${paths}; do probe "token:$p" -H "X-aws-ec2-metadata-token: $T" "$M$p"; done`,
    "probe 'json:/' -H \"X-aws-ec2-metadata-token: $T\" -H 'Accept: application/json' \"$M/\"",
    "probe 'json:/latest/' -H \"X-aws-ec2-metadata-token: $T\" -H 'Accept: application/json' \"$M/latest/\"",
    "probe 'json:/latest/meta-data/' -H \"X-aws-ec2-metadata-token: $T\" -H 'Accept: application/json' \"$M/latest/meta-data/\"",
    "probe 'xmt:/latest/meta-data/' -H \"X-metadata-token: $T\" \"$M/latest/meta-data/\"",
    "probe 'notoken:/' \"$M/\"",
    "probe 'notoken:/latest/meta-data/' \"$M/latest/meta-data/\"",
    "probe 'notoken:/latest/user-data' \"$M/latest/user-data\"",
    "printf '@@ENV\\n'; env | grep -i -E 'cmux|freestyle|meta' | head -c 2000; printf '\\n@@END\\n'",
    "printf '@@FILES\\n'; ls -la /run/freestyle /etc/freestyle /var/lib/freestyle /run/cloud-init /var/lib/cloud 2>&1 | head -c 2000; printf '\\n@@END\\n'",
    "printf '@@MOUNTS\\n'; grep -i -E 'virtiofs|9p|cdrom|iso9660|freestyle|meta' /proc/mounts 2>&1 | head -c 1000; printf '\\n@@END\\n'",
    "printf '@@DMI\\n'; cat /sys/class/dmi/id/product_serial /sys/class/dmi/id/product_uuid /sys/class/dmi/id/sys_vendor 2>&1 | head -c 600; printf '\\n@@END\\n'",
    "printf '@@CMDLINE\\n'; cat /proc/cmdline 2>&1 | head -c 600; printf '\\n@@END\\n'",
  ].join("\n");
}

type Probed = { path: string; status: string | null; body: string };

function parseProbe(stdout: string): { tokenOk: boolean; probes: Probed[]; extras: Record<string, string> } {
  const lines = stdout.split("\n");
  let tokenOk = false;
  const probes: Probed[] = [];
  const extras: Record<string, string> = {};
  let current: { kind: "path" | "extra"; name: string; lines: string[] } | null = null;
  for (const line of lines) {
    if (line.startsWith("@@TOKEN ")) { tokenOk = line.slice(8).trim() === "1"; continue; }
    if (line.startsWith("@@PATH ")) { current = { kind: "path", name: line.slice(7), lines: [] }; continue; }
    if (line === "@@ENV" || line === "@@FILES" || line === "@@MOUNTS" || line === "@@DMI" || line === "@@CMDLINE") { current = { kind: "extra", name: line.slice(2).toLowerCase(), lines: [] }; continue; }
    if (line === "@@END") {
      if (current?.kind === "path") {
        let status: string | null = null;
        const body: string[] = [];
        for (const l of current.lines) {
          if (l.startsWith("@@STATUS ")) status = l.slice(9).trim();
          else body.push(l);
        }
        probes.push({ path: current.name, status, body: body.join("\n").trim() });
      } else if (current?.kind === "extra") {
        extras[current.name] = current.lines.join("\n").trim();
      }
      current = null;
      continue;
    }
    current?.lines.push(line);
  }
  return { tokenOk, probes, extras };
}

async function exec(vm: Vm, command: string, timeoutMs = 20_000) {
  const result = await bounded(vm.exec({ command, timeoutMs, linuxUser: "root" }), timeoutMs + 15_000, "exec");
  return { exitCode: result.statusCode ?? null, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

async function waitForExec(vm: Vm, budgetMs = 60_000): Promise<number> {
  const startedAt = performance.now();
  while (performance.now() - startedAt < budgetMs) {
    try {
      const r = await exec(vm, "true", 5_000);
      if (r.exitCode === 0) return Math.round(performance.now() - startedAt);
    } catch {
      // still booting
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("guest exec never succeeded");
}

function findValue(probes: Probed[], value: string): Probed | undefined {
  return probes.find((p) => p.status === "200" && p.body.includes(value));
}

async function main() {
  mkdirSync(outDir, { recursive: true });
  const startedAt = new Date().toISOString();
  console.error(`probe-metadata: image=${image} out=${outDir}`);
  const created = await bounded(fs.vms.create({
    snapshotId: image,
    displayName: "cmux metadata probe (throwaway)",
    idleTimeoutSeconds: 600,
    metadata: { cmux: "probe", [METADATA_KEY]: PROBE_VALUE },
    firewall: { rules: freestyleFirewallRules() },
  }), 120_000, "create");
  const { vm, vmId } = created;
  console.error(`probe-metadata: created ${vmId}`);
  const report: Record<string, unknown> = { startedAt, image, vmId, metadataSent: { cmux: "probe", [METADATA_KEY]: PROBE_VALUE } };
  try {
    report.firstExecMs = await waitForExec(vm);
    const data = await bounded(vm.data(), 30_000, "data");
    report.apiMetadata = data.metadata;
    const first = await exec(vm, probeScript(), 60_000);
    const parsed = parseProbe(first.stdout);
    report.tokenOk = parsed.tokenOk;
    report.probeExit = first.exitCode;
    report.extras = parsed.extras;
    const raw: Record<string, string> = {};
    for (const p of parsed.probes) raw[p.path] = `[${p.status ?? "?"}] ${p.body.slice(0, 200)}`;
    const hit = findValue(parsed.probes, PROBE_VALUE);
    let updateVisible = false;
    let updatedRaw: Record<string, string> = {};
    let apiMetadataAfterUpdate: unknown = null;
    const updated = await bounded(vm.update({ metadata: { [METADATA_KEY]: RENAMED_VALUE } }), 60_000, "update");
    apiMetadataAfterUpdate = updated.metadata;
    await new Promise((resolve) => setTimeout(resolve, 1_500));
    const second = await exec(vm, probeScript(), 60_000);
    const parsed2 = parseProbe(second.stdout);
    for (const p of parsed2.probes) updatedRaw[p.path] = `[${p.status ?? "?"}] ${p.body.slice(0, 200)}`;
    const hit2 = findValue(parsed2.probes, RENAMED_VALUE);
    updateVisible = !!hit2;
    const readable = !!hit;
    const result = {
      readable,
      path: hit ? hit.path.replace(/^(token|json|xmt|notoken):/, "") : null,
      pathMode: hit ? hit.path.split(":")[0] : null,
      updateVisible,
      updatePath: hit2 ? hit2.path.replace(/^(token|json|xmt|notoken):/, "") : null,
      tokenOk: parsed.tokenOk,
      apiMetadata: report.apiMetadata,
      apiMetadataAfterUpdate,
      firstExecMs: report.firstExecMs,
      image,
      vmId,
      startedAt,
      finishedAt: new Date().toISOString(),
      raw,
      rawAfterUpdate: updatedRaw,
      extras: parsed.extras,
    };
    writeFileSync(join(outDir, "metadata-probe.json"), JSON.stringify(result, null, 2) + "\n");
    const md = [
      "# In-guest metadata probe (issue #13070, stream 5 step 0)",
      "",
      `- image: \`${image}\` (md desktop default), vm ${vmId}, ${startedAt}`,
      `- metadata sent at create: \`{ cmux: "probe", "${METADATA_KEY}": "${PROBE_VALUE}" }\`; API \`vm.data().metadata\`: \`${JSON.stringify(result.apiMetadata)}\``,
      `- token dance (PUT /latest/api/token): ${parsed.tokenOk ? "ok" : "FAILED"}`,
      `- **readable in guest: ${readable ? "YES" : "NO"}**${hit ? ` at \`${hit.path}\`` : ""}`,
      `- \`vm.update({ metadata })\` visible in guest: ${updateVisible ? "YES" : "NO"}${hit2 ? ` at \`${hit2.path}\`` : ""}; API metadata after update: \`${JSON.stringify(apiMetadataAfterUpdate)}\``,
      "",
      "## Paths (status, first 200 bytes)",
      "",
      ...Object.entries(raw).map(([k, v]) => `- \`${k}\`: ${JSON.stringify(v)}`),
      "",
      "## Guest environment / files / mounts / DMI / cmdline",
      "",
      ...Object.entries(parsed.extras).map(([k, v]) => `### ${k}\n\n\`\`\`\n${v || "(empty)"}\n\`\`\`\n`),
      "",
      `Decision: ${readable ? "option (i): pass the prompt name as create metadata; the supervisor writes /etc/cmux/vm-name from it." : "option (ii): the guest cannot read VM metadata; deliver the prompt name through the SDK's create-time exec."}`,
      "",
    ].join("\n");
    writeFileSync(join(outDir, "metadata-probe.md"), md);
    console.log(JSON.stringify({ readable, path: result.path, pathMode: result.pathMode, updateVisible, tokenOk: parsed.tokenOk, vmId }, null, 2));
  } finally {
    try {
      await bounded(vm.delete(), 60_000, "delete");
      console.error(`probe-metadata: deleted ${vmId}`);
    } catch (error) {
      console.error(`probe-metadata: CLEANUP NEEDED vm=${vmId}: ${error instanceof Error ? error.message : String(error)}`);
      process.exitCode = 1;
    }
  }
}

main().catch((error) => {
  console.error(`probe-metadata: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  process.exit(1);
});
