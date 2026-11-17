// Every key the page's attaches send is one the Swift host's params rule takes for `_acpmux/attach`
// (AcpmuxPaneMethods+Params.swift `knownParams`). The host refuses any other key as
// `transport.intent_invalid` and the chat's open fails: `settled` once (cmux#42185), then the row
// store's `hold` (#43616), which made a relaunched chat say its open failed and then shift in.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { plainAttach } from "./attachParams";
import { holdAttach } from "./rows/holdKinds";

const RULE = readFileSync(
  `${import.meta.dir}/../../../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift`,
  "utf8",
);

/// The params the host's rule names for `method`: its `"method": ([...], [...])` line's first list.
function hostParams(method: string): string[] {
  const line = RULE.match(new RegExp(`"${method.replace(/[/.]/g, "\\$&")}":\\s*\\(\\[([^\\]]*)\\]`));
  expect(line).not.toBeNull();
  return [...line![1]!.matchAll(/"([^"]+)"/g)].map((match) => match[1]!);
}

test("every attach the page sends passes the host's params rule", () => {
  const taken = new Set(hostParams("_acpmux/attach"));
  const sent = [
    plainAttach("s", { settled: true, visible: true, local: true, maxBytes: 131_072 }),
    plainAttach("s", { settled: false, visible: false, local: false, maxBytes: 131_072 }),
    holdAttach("s", true),
  ];
  for (const params of sent) {
    expect(params).toBeDefined();
    expect(Object.keys(params!).filter((key) => !taken.has(key))).toEqual([]);
  }
});
