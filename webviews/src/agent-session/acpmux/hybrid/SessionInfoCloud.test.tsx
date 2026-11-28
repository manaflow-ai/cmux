// Runs On in the Environment list is a row like its neighbors (cmux#56150): the whole row opens the
// menu and the choice is its muted end value, never a ghost pill, which drew WebKit's grey bezel with
// a white border because the agent pane does not load ui.css.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import { SessionInfoCloudRows } from "./SessionInfoCloud";
import type { HybridPin } from "./hybridModel";

function runsOn(pin: HybridPin): HTMLElement {
  const html = renderToStaticMarkup(
    <ul>
      <SessionInfoCloudRows
        control={{ view: { lit: false, pin, at: "local", used: 0, total: 0 }, setPin: () => undefined }}
      />
    </ul>,
  );
  const host = new JSDOM(html).window.document;
  const row = host.querySelector<HTMLElement>('[data-testid="session-info-runs-on"]');
  if (!row) throw new Error("no Runs On row");
  return row;
}

for (const [pin, key] of [
  ["local", "hybrid.pin.local"],
  ["cloud", "hybrid.pin.cloud"],
  ["auto", "composer.auto"],
] as const) {
  test(`Runs On (${pin}) is a whole-row menu trigger with its choice as the row's end value`, () => {
    const row = runsOn(pin);
    const trigger = row.querySelector("button");
    expect(trigger?.classList.contains("acpmux-session-info-row")).toBe(true);
    expect(trigger?.classList.contains("acpmux-session-info-row--button")).toBe(true);
    expect(trigger?.getAttribute("data-menu")).toBe("RunsOn");
    expect(row.querySelectorAll("button")).toHaveLength(1);
    expect(row.querySelector(".ui-ghost")).toBeNull();
    expect(trigger?.querySelector(".acpmux-session-info-row__name")?.textContent).toBe(translate("hybrid.pin"));
    expect(trigger?.querySelector(".acpmux-session-info-row__end")?.textContent).toBe(translate(key));
  });
}
