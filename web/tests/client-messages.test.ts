import { describe, expect, test } from "bun:test";
import enMessages from "../messages/en.json";
import {
  pruneClientMessages,
  sharedClientMessages,
} from "../i18n/client-messages";

describe("client message catalogs", () => {
  test("the shared catalog drops subtree-only namespaces and keeps the dashboard", () => {
    const shared = sharedClientMessages(enMessages);

    expect(shared.docs).toBeUndefined();
    // Read by the download confirmation outside the community route.
    expect(shared.community).toBeDefined();
    expect(shared.dashboard).toBeDefined();
    expect(shared.common).toBeDefined();
    expect(shared.landing).toBeDefined();
    // The docs namespace alone is about half of the catalog.
    const before = JSON.stringify(pruneClientMessages(enMessages)).length;
    const after = JSON.stringify(shared).length;
    expect(after).toBeLessThan(before * 0.55);
  });

  test("the subtree catalog keeps docs for its nested provider", () => {
    const pruned = pruneClientMessages(enMessages);

    expect(pruned.docs).toBeDefined();
    expect(enMessages.docs).toBeDefined();
  });
});
