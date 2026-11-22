import { expect, test } from "bun:test";
import type { SessionSummary } from "../src/core/acp.ts";
import { childPermissionPrompt } from "../src/core/rules.ts";

const child: SessionSummary = {
  sessionId: "s_w",
  name: "writer",
  harness: "claude",
  cwd: "/work",
  status: "waiting",
  pendingPermissions: 1,
  stateSeq: 1,
  preview: null,
  tags: {},
};

// Float gap (plans/cmux-next/chief-mac.md section 4): the cores write floats
// differently, so no code compares this text between them and the corpus has
// no floats in rawInput. This pins the TypeScript text; cmux-chief rules.rs
// pins the Rust text ({"x":1.0}).
test("rawInput float text is JavaScript's: {\"x\":1.0} is written {\"x\":1}", () => {
  const request = JSON.parse('{"toolCall":{"title":"t","rawInput":{"x":1.0,"a":2}}}') as Record<string, unknown>;
  expect(childPermissionPrompt(child, request)).toContain('\nInput: {"a":2,"x":1}\n');
});
