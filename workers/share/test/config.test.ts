// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

function tomlSection(source: string, name: string): string | null {
  const marker = `[${name}]`;
  const start = source.indexOf(marker);
  if (start < 0) return null;
  const body = source.slice(start + marker.length);
  const nextSection = body.search(/^\s*\[/m);
  return nextSection < 0 ? body : body.slice(0, nextSection);
}

describe("Worker deploy configuration privacy", () => {
  it("disables automatic invocation logs without disabling explicit logs", () => {
    const configs = readdirSync(ROOT)
      .filter((name) => /^wrangler(?:\..+)?\.toml$/.test(name))
      .sort();
    expect(configs).toEqual(["wrangler.dev.toml", "wrangler.toml"]);

    for (const config of configs) {
      const source = readFileSync(`${ROOT}/${config}`, "utf8");
      const logs = tomlSection(source, "observability.logs");
      expect(logs).not.toBeNull();
      expect(logs).toMatch(/^\s*enabled\s*=\s*true\s*$/m);
      expect(logs).toMatch(/^\s*invocation_logs\s*=\s*false\s*$/m);
    }
  });
});
