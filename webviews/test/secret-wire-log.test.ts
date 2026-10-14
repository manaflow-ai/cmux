// The pane's wire log can be exported (Save Log), so a secret card's answer (cx-ncc.42) is logged
// without its value: the method, the session and the card's id stay, the value never does.
import { expect, test } from "bun:test";
import { AcpWireLog } from "../src/agent-session/acpmux/wire";

test("a secret card's answer is logged without its value", () => {
  const log = new AcpWireLog(
    () => 0,
    () => 0,
  );
  const frame = JSON.stringify({
    jsonrpc: "2.0",
    id: 7,
    method: "_acpmux/secret_submit",
    params: { sessionId: "s1", secretId: "card-1", value: "sk-live-4f9a2c7e1b" },
  });
  log.sent(frame, "_acpmux/secret_submit", 7);
  const exported = log.exportJsonl();
  expect(exported).not.toContain("sk-live-4f9a2c7e1b");
  expect(exported).toContain("card-1");
  expect(exported).toContain("_acpmux/secret_submit");
});
