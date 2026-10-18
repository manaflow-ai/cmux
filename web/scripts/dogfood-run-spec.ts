import {
  normalizeRunSpec,
  redactedRunSpec,
  runSpecDigest,
} from "../services/runs/spec";

const sha = (letter: string) => `sha256:${letter.repeat(64)}`;
const spec = normalizeRunSpec({
  schema: "cmux.run/v1",
  operationId: `dogfood-${Date.now()}`,
  source: {
    repository: "manaflow-ai/cmux-next",
    ref: "main",
    commit: "c".repeat(40),
    setupManifestDigest: sha("a"),
    imageDigest: sha("b"),
  },
  intent: { digest: sha("d") },
  recipe: { id: "ui-tournament", version: 1 },
  variants: [
    { id: "alpha", label: "alpha", instructionDigest: sha("e") },
    { id: "beta", label: "beta", instructionDigest: sha("f") },
  ],
  workspace: { kind: "persistent", desiredKey: "dogfood-box" },
  resources: { maxAttempts: 2, maxConcurrent: 2, memoryClass: "standard", cpuClass: "standard" },
  routing: { backend: "freestyle" },
  capabilities: { secretRefs: ["team/staging/github"], networkProfile: "private-egress" },
  checks: ["source.verified", "setup.verified"],
  policy: { mode: "thunderdome", humanApprovalRequired: true, evidenceKinds: ["screenshot", "patch"] },
});

const redacted = redactedRunSpec(spec);
const output = JSON.stringify({
  schema: redacted.schema,
  specDigest: runSpecDigest(redacted),
  operationId: redacted.operationId,
  variants: redacted.variants.map(({ id, label }) => ({ id, label })),
  maxConcurrent: redacted.resources.maxConcurrent,
  secretRefCount: redacted.capabilities.secretRefs.length,
  redacted: true,
});

if (output.includes("secret") && !output.includes("secretRefCount")) {
  throw new Error("dogfood output unexpectedly contains a secret value");
}

console.log(output);
