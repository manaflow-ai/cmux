// l10n-allow-file: test fixture recap text, not shipped UI.
// A recap in a read-only transcript (a shared chat's guest) or a replay draws no ×: there it would
// do nothing, or act on the live chat (App.tsx ReadOnlyRecapRow, readOnlyRegistry, replayRegistry).
import { expect, test } from "bun:test";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { readOnlyRegistry } from "../src/agent-session/acpmux/App";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row: AcpmuxRow = {
  id: "recap-2",
  version: 1,
  at: 0,
  kind: "recap",
  recap: { key: "chat:2", text: "Where it stands: the fix is in." },
};

test("a read-only transcript's recap row has no dismiss button", () => {
  const ReadOnly = readOnlyRegistry.recap as (props: { row: AcpmuxRow }) => ReactNode;
  const html = renderToStaticMarkup(<ReadOnly row={row} />);
  expect(html).toContain("Where it stands: the fix is in.");
  expect(html).not.toContain("cv-recap__close");
});
