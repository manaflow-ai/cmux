// Every attach the pane sends passes the app host's params rule (P1, AcpmuxPaneMethods+Params.swift
// `knownParams`). The host refuses a frame with a param outside its method's list as
// `transport.intent_invalid` and never sends it to acpmux. The hold attach (rows/holdKinds.ts, a chat whose rows
// come from the store) sent `hold`, which the list did not name: after a restart on Leo's NIGHTLY
// (2026-11-16 23:28:49Z) both of the chat's attaches were refused that way, and the pane showed its error line
// with Retry above the composer ("then it said something went wrong with a retry button just above the
// composer"). acpmux takes the hold (server/requests.rs, `attach-hold-v1`); only the host's list missed it.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { plainAttach } from "../src/agent-session/acpmux/attachParams";
import { holdAttach } from "../src/agent-session/acpmux/rows/holdKinds";

const repo = path.resolve(import.meta.dir, "../..");
const paramsSource = readFileSync(
  path.join(repo, "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift"),
  "utf8",
);

/// The top-level params the host's `knownParams` lets `method` carry: the first set of its entry.
function hostParams(method: string): string[] {
  const line = paramsSource.split("\n").find((text) => text.trimStart().startsWith(`"${method}": (`));
  expect(line).toBeDefined();
  const first = /\(\[([^\]]*)\]/.exec(line!)?.[1] ?? "";
  return [...first.matchAll(/"([^"\\]+)"/g)].map((match) => match[1]!);
}

test("each attach the pane sends names only params the app host's attach rule takes", () => {
  const known = hostParams("_acpmux/attach");
  const sent = [
    holdAttach("s1", true),
    holdAttach("s1", false),
    ...[true, false].flatMap((settled) =>
      [true, false].map((local) => plainAttach("s1", { settled, visible: true, local, maxBytes: 1 << 20 })),
    ),
  ];
  for (const params of sent) {
    expect(params).toBeDefined();
    for (const key of Object.keys(params!)) expect(known).toContain(key);
  }
});
