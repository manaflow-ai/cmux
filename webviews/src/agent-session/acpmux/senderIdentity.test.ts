// l10n-allow-file: sender/session fixtures.
import { expect, test } from "bun:test";
import { sessionEntry, sessionTitle } from "./sessionList";
import { incomingPrompt } from "./conversation/incomingMessage";

test("a peer's session name is the headline, not the peer machine", () => {
  const remote = sessionEntry({
    sessionId: "peer-review",
    name: "gcp-codex-lane-10/pr-row",
    peer: "gcp-codex-lane-10",
    harness: "codex",
  });
  expect(sessionTitle(remote)).toBe("pr-row");
  expect(remote.displayTitle).toBe("pr-row");
  expect(remote.peer).toBe("gcp-codex-lane-10");
});

test("an ordinary slash in a session name is preserved without peer metadata", () => {
  expect(sessionTitle({ sessionId: "local", name: "team/review" })).toBe("team/review");
});

test("a body signature cannot replace the recorded sender's identity", () => {
  const message = incomingPrompt("From gcp-codex-lane-10. The review is ready.", {
    client: "acpmux-peer#fixture",
    _meta: {
      provenance: {
        kind: "agent_message",
        from: "fromAgent",
        fromName: "gcp-codex-lane-10/pr-row",
      },
    },
  });
  expect(message?.kind === "message" && message.message.name).toBe("gcp-codex-lane-10/pr-row");
});
