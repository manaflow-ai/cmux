// The model picker's catalog is built once per chat, not once per reader. The pane and the chat's
// composer chips each call usePickerCatalog on their first frame with the same inputs (each with its own
// session object), and each build walks the whole catalog: about 10 ms of a cold chat open.
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { resetModelCatalogForTests, usePickerCatalog } from "../src/agent-session/acpmux/modelCatalogHost";
import type { PickerCatalog } from "../src/agent-session/acpmux/modelCatalogData";

type Session = Parameters<typeof usePickerCatalog>[1];

function read(sessions: Session[], acpmux: Parameters<typeof usePickerCatalog>[0] = []): PickerCatalog[] {
  const seen: PickerCatalog[] = [];
  function Reader({ session }: { session: Session }) {
    seen.push(usePickerCatalog(acpmux, session).catalog);
    return null;
  }
  renderToStaticMarkup(
    <QueryClientProvider client={new QueryClient()}>
      {sessions.map((session, at) => (
        <Reader key={at} session={session} />
      ))}
    </QueryClientProvider>,
  );
  return seen;
}

describe("usePickerCatalog", () => {
  test("readers with the same inputs share one build", () => {
    resetModelCatalogForTests();
    const [pane, chips] = read([
      { harness: "claude", model: "default" },
      { harness: "claude", model: "default" },
    ]);
    expect(pane).toBeDefined();
    expect(chips).toBe(pane!);
  });

  test("a changed input builds again", () => {
    resetModelCatalogForTests();
    const [claude, codex] = read([{ harness: "claude" }, { harness: "codex" }]);
    expect(codex).not.toBe(claude!);
    const [first] = read([{ harness: "claude" }], []);
    const [other] = read([{ harness: "claude" }], []);
    // A new acpmux list (a new snapshot's catalog) is a new input, even when it is equal.
    expect(other).not.toBe(first!);
  });
});
