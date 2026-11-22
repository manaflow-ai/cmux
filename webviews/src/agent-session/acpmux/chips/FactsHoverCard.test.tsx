// l10n-allow-file: test fixture paths, not shipped UI.
// What a row's text cannot show shows on its hover card (Chief, 2026-11-21, after the tooltip cuts:
// "Information sighted users lost must still show somewhere visible ... aria-description alone is
// not enough"). The card opens on focus at once, shows every fact whole, and its facts are the
// trigger's description for screen readers on any role.
import { afterEach, expect, test } from "bun:test";
import type { ReactNode } from "react";
import { describedText, factsCardText, renderInDom } from "../../../../test/support/factsCard";
import { WithFacts, Described } from "./FactsHoverCard";

const PATH = "/Users/you/fun/very/long/folder/that/the/row/cuts/payments-service";
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

test("a cut folder name shows its whole path on its card, and the path describes it", async () => {
  const container = await render(
    <WithFacts
      facts={[
        { value: PATH, code: true },
        { label: "Branch", value: "main" },
      ]}
    >
      {(trigger) => (
        <span className="project" {...trigger}>
          payments-service
        </span>
      )}
    </WithFacts>,
  );
  const project = container.querySelector(".project")!;
  // The card is closed until hover or focus: a row's list shows none.
  expect(container.ownerDocument.querySelector("[data-facts-card]")).toBeNull();
  expect(await factsCardText(project)).toBe(`${PATH}Branchmain`);
  expect(describedText(project)).toBe(`${PATH}, Branch: main`);
});

test("with no facts there is no card and no description", async () => {
  const container = await render(
    <WithFacts facts={[undefined, { value: "  " }, false]}>
      {(trigger) => (
        <span className="project" {...trigger}>
          payments-service
        </span>
      )}
    </WithFacts>,
  );
  const project = container.querySelector(".project")!;
  expect(await factsCardText(project)).toBe("");
  expect(project.hasAttribute("aria-describedby")).toBe(false);
});

test("a help sentence describes its control on any role", async () => {
  const container = await render(
    <Described text="Reloads the app">
      {(described) => (
        <button type="button" {...described}>
          Reload
        </button>
      )}
    </Described>,
  );
  expect(describedText(container.querySelector("button")!)).toBe("Reloads the app");
});
