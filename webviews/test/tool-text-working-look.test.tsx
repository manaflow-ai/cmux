// l10n-allow-file: test fixture paths and file text, not shipped UI.
// A running transcript row holds its words once in every look but the Debug-only "shimmer"
// (ToolText.tsx). The shimmer look draws a lit copy of the words under a moving band; the other
// looks (the default "breathe", "spinner") have no band, so they must not mount the copy: it made
// React render and reconcile every running row's label twice (links, buttons, InlineFailureCause
// reading localStorage), and the row's textContent read "Writing x.tsWriting x.ts". A row whose
// words are plain text draws the lit copy as generated content (`data-text`), so even the shimmer
// look holds those words once. The look comes from the theme the host pushes (applyAgentTheme),
// the same value the stylesheet reads from `data-working-look`.
import { act } from "react";
import { afterEach, expect, test } from "bun:test";
import { setupText, FOLDER, toolCall, useDom } from "./support/unknownWrite";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";

const dom = useDom();
const PATH = `${FOLDER}/x.ts`;
const fragment = { type: "diff", path: PATH, oldText: null, newText: setupText, _meta: { acpmux: { fragment: true } } };
/// Claude Code's Write while it runs: a lone in_progress edit with a diff, drawn as a tool group.
const running = [
  { title: "Write", kind: "edit", status: "pending" },
  {
    title: "Write x.ts",
    kind: "edit",
    status: "in_progress",
    rawInput: { file_path: PATH, content: setupText },
    content: [fragment],
    locations: [{ path: PATH }],
  },
];

async function look(workingLook: "breathe" | "shimmer" | "spinner") {
  const { applyAgentTheme } = await import("../src/agent-session/shared/theme");
  await act(async () => applyAgentTheme({ isDark: false, workingLook } as never));
}

async function runningWrite() {
  const { toolGroups } = await import("../src/agent-session/acpmux/conversation/toolGroups");
  const { ToolGroupRow } = await import("../src/agent-session/acpmux/conversation/ToolGroupRow");
  const item: AcpmuxActivity = await toolCall("w-look", running);
  // Drawn where the transcript draws it (TurnRows.tsx groupNode): a lone edit with a diff is a group.
  const [group] = toolGroups([item]);
  if (group?.type !== "group") throw new Error(`a running Write with a diff drew as ${group?.type}, not a group`);
  await dom.render(<ToolGroupRow kind={group.kind} items={group.items} disclosureKey="group:w-look" />);
}

afterEach(async () => {
  await look("breathe");
});

for (const name of ["breathe", "spinner"] as const) {
  test(`in the ${name} look a running row mounts its words once`, async () => {
    await look(name);
    await runningWrite();
    const host = dom.host();
    expect(host.querySelector(".cv-tool__lit")).toBeNull();
    expect(host.querySelector(".cv-tool__shine")).toBeNull();
    expect(dom.text(".cv-tool__text")).toBe("Writing x.ts");
    // The file name is one link, not one plus a hidden copy.
    expect(host.querySelectorAll("[data-path]").length).toBe(1);
  });
}

test("in the shimmer look a running row with marks carries one inert lit copy", async () => {
  await look("shimmer");
  await runningWrite();
  const host = dom.host();
  const shine = host.querySelector(".cv-tool__shine");
  expect(shine).not.toBeNull();
  expect(shine!.getAttribute("aria-hidden")).toBe("true");
  expect(shine!.hasAttribute("inert")).toBe(true);
  expect(host.querySelectorAll(".cv-tool__lit").length).toBe(1);
});

test("a look change mounts and unmounts the lit copy on a shown row", async () => {
  await look("breathe");
  await runningWrite();
  expect(dom.host().querySelector(".cv-tool__lit")).toBeNull();
  await look("shimmer");
  expect(dom.host().querySelector(".cv-tool__lit")).not.toBeNull();
  await look("breathe");
  expect(dom.host().querySelector(".cv-tool__lit")).toBeNull();
  expect(dom.text(".cv-tool__text")).toBe("Writing x.ts");
});

test("in the shimmer look a plain-text row holds its words once (generated lit copy)", async () => {
  const { ToolText } = await import("../src/agent-session/acpmux/conversation/ToolText");
  await look("shimmer");
  await dom.render(<ToolText working>Compacting</ToolText>);
  const lit = dom.host().querySelector(".cv-tool__lit");
  expect(lit).not.toBeNull();
  expect(lit!.getAttribute("data-text")).toBe("Compacting");
  expect(lit!.textContent).toBe("");
  expect(dom.text(".cv-tool__text")).toBe("Compacting");
});
