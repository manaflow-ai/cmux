// l10n-allow-file: test fixture agent names and folders, not shipped UI.
// An agent chip says only the last part of the agent's name; its whole name (the agent's id) and its
// title show on its hover card, as a row's cut folder shows its whole path (Chief, 2026-11-21, after
// the tooltip cuts: "Information sighted users lost must still show somewhere visible ... agent ID").
import { afterEach, expect, test } from "bun:test";
import type { ReactNode } from "react";
import { AgentRow, OwnerChips } from "../src/pages/chief-views/parts";
import type { ChiefAgent } from "../src/pages/chief-views/types";
import type { Strings } from "../src/pages/shared/i18n";
import { factsCardText, renderInDom } from "./support/factsCard";

const strings: Strings = { language: "en", t: (key) => key, format: (key) => key };
const agent: ChiefAgent = {
  id: "a-41",
  kind: "chat",
  name: "cmux-lawrence/tooltip-redesign",
  title: "Tooltip gaps",
  machine: "local",
  folder: "/Users/you/fun/cmux-worktrees/a-tooltip-redesign",
  state: "working",
};
let close: (() => Promise<void>) | undefined;

async function render(node: ReactNode): Promise<HTMLElement> {
  const page = await renderInDom(node);
  close = page.close;
  return page.container;
}

afterEach(async () => {
  await close?.();
  close = undefined;
});

test("an owner chip shows the agent's title and whole name on its hover card", async () => {
  const container = await render(<OwnerChips owners={[agent]} strings={strings} />);
  const chip = container.querySelector(".cv-owner")!;
  expect(chip.querySelector(".cv-owner-name")?.textContent).toBe("tooltip-redesign");
  expect(await factsCardText(chip)).toBe("Tooltip gapscmux-lawrence/tooltip-redesign");
});

test("a row's folder name shows its whole path on its hover card", async () => {
  const container = await render(<AgentRow agent={agent} strings={strings} onOpen={() => {}} />);
  const folder = container.querySelector(".cv-row-folder")!;
  // The row shows the folder's last two names; the card shows the whole path.
  expect(folder.textContent).toBe("cmux-worktrees/a-tooltip-redesign");
  expect(await factsCardText(folder)).toBe(agent.folder!);
});
