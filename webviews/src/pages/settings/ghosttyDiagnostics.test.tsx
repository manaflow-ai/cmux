// R92 diagnostics: Terminal lists the Ghostty config keys and keybind actions of the user's files
// that cmux does not apply (cmux.settings.host.lists `ghostty_diagnostics`, live through
// cmux.settings.host.changed), each with its reason, cmux replacement and file:line, and the lines
// Ghostty could not read; with none, one line says everything applies.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { GhosttyDiagnostic } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const diagnostics: GhosttyDiagnostic[] = [
  {
    kind: "key",
    name: "window-decoration",
    file: "/Users/me/.config/ghostty/config",
    line: 2,
    reason: "superseded",
    replacement: "window.titlebar",
  },
  {
    kind: "key",
    name: "quick-terminal-position",
    file: "/Users/me/.config/ghostty/config",
    line: 4,
    reason: "later",
    replacement: null,
  },
  {
    kind: "keybind-action",
    name: "inspector",
    file: "/Users/me/.config/ghostty/keys",
    line: 7,
    reason: "not-applicable",
    replacement: null,
  },
  {
    kind: "invalid",
    name: "/Users/me/.config/ghostty/config:5: bogus: unknown field",
    file: null,
    line: null,
    reason: null,
    replacement: null,
  },
];

test("Terminal lists each Ghostty line cmux does not apply, with its reason and source", async () => {
  const page = await renderPage({ path: "/settings/terminal" });
  await act(async () => page.provider.setHost({ ...page.provider.host, ghostty_diagnostics: diagnostics }));
  await settle();
  const card = page.container.querySelector<HTMLElement>('[data-card="ghostty-diagnostics"]')!;
  expect(card).not.toBeNull();
  expect(card.textContent).toContain("Not Applied from Your Ghostty Config");
  const rows = [...card.querySelectorAll<HTMLElement>("[data-ghostty-diagnostic]")];
  expect(rows.map((row) => row.dataset.ghosttyDiagnostic)).toEqual([
    "window-decoration",
    "quick-terminal-position",
    "inspector",
    "/Users/me/.config/ghostty/config:5: bogus: unknown field",
  ]);
  expect(rows[0]!.textContent).toContain("Replaced by the cmux setting window.titlebar");
  expect(rows[0]!.textContent).toContain("/Users/me/.config/ghostty/config, line 2");
  expect(rows[1]!.textContent).toContain("Not supported in cmux yet");
  expect(rows[2]!.textContent).toContain("Keybind action: inspector");
  expect(rows[2]!.textContent).toContain("Not used in cmux");
  expect(rows[3]!.textContent).toContain("Ghostty could not read this line");

  await act(async () => page.provider.setHost({ ...page.provider.host, ghostty_diagnostics: [] }));
  await settle();
  const empty = page.container.querySelector<HTMLElement>('[data-card="ghostty-diagnostics"]')!;
  expect(empty.querySelectorAll("[data-ghostty-diagnostic]").length).toBe(0);
  expect(empty.textContent).toContain("Every setting in your Ghostty config applies in cmux.");
  page.unmount();
});
