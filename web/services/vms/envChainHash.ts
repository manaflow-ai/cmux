// TypeScript mirror of the env-layer chain hash computed by the cmux CLI
// (CLI/CMUXCLI+VMEnvSpec.swift). The server currently treats chain hashes as
// opaque team-scoped cache keys; this mirror exists so a later server-side
// recompute is a drop-in, and so shared test vectors pin both implementations
// to the same bytes.

import { createHash } from "node:crypto";

export type EnvChainStep = {
  readonly run: string;
};

function sha256Hex(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function jsonEscaped(value: string): string {
  let out = '"';
  for (const char of value) {
    const code = char.codePointAt(0) ?? 0;
    if (char === '"') out += '\\"';
    else if (char === "\\") out += "\\\\";
    else if (char === "\n") out += "\\n";
    else if (char === "\r") out += "\\r";
    else if (char === "\t") out += "\\t";
    else if (code < 0x20) out += `\\u${code.toString(16).padStart(4, "0")}`;
    else out += char;
  }
  return out + '"';
}

export function canonicalStepJSON(run: string, env: Readonly<Record<string, string>>): string {
  const keys = Object.keys(env).sort();
  const inner = keys.map((key) => `${jsonEscaped(key)}:${jsonEscaped(env[key] ?? "")}`).join(",");
  return `{"env":{${inner}},"run":${jsonEscaped(run)}}`;
}

export function envChainHashes(input: {
  readonly provider: string;
  readonly baseImageId: string;
  readonly env: Readonly<Record<string, string>>;
  readonly steps: readonly EnvChainStep[];
}): string[] {
  let current = sha256Hex(`cmux-env-v1\n${input.provider}\n${input.baseImageId}`);
  const hashes: string[] = [];
  for (const step of input.steps) {
    current = sha256Hex(`${current}\n${canonicalStepJSON(step.run, input.env)}`);
    hashes.push(current);
  }
  return hashes;
}
