// One Runs On order everywhere the choice appears (cmux#57117): This Mac, Auto, Cloud. Auto sits
// between the two places it picks from. The composer's Where menu (This Mac, Auto, Cloud, Other
// devices) is pinned in EnvironmentPicker.test.tsx; this file pins the shared list and every other
// control that reads it: Session Info's Runs On menu and the place control. The Cloud toggle's
// segments are pinned in CloudTriToggle.test.tsx.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { translate, type Translate } from "../src/agent-session/acpmux/i18n";
import { RUNS_ON_ORDER, inRunsOnOrder } from "../src/agent-session/acpmux/runsOnOrder";
import { environmentSection } from "../src/agent-session/acpmux/session-info/native/environment";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { PlaceControl } from "../src/agent-session/acpmux/place/PlaceControl";
import { PLACES } from "../src/agent-session/acpmux/place/fixtures";

const t: Translate = (key, values) => translate(key, values, "en");
const noop = () => undefined;

function parse(element: React.ReactElement): Document {
  return new JSDOM(renderToStaticMarkup(element)).window.document;
}

test("the shared order is This Mac, Auto, Cloud", () => {
  expect(RUNS_ON_ORDER).toEqual(["local", "auto", "cloud"]);
  // Rows given in any order come back in that order, an empty choice left out.
  expect(inRunsOnOrder({ cloud: ["c"], local: ["m1", "m2"], auto: ["a"] })).toEqual(["m1", "m2", "a", "c"]);
  expect(inRunsOnOrder({ cloud: ["c"], local: ["m"] })).toEqual(["m", "c"]);
});

test("Session Info's Runs On menu lists This Mac, Auto, Cloud", () => {
  const section = environmentSection(
    {
      summary: { sessionId: "chat", hostKind: "local", host: "This Mac" },
      cloud: { view: { lit: false, pin: "auto", at: "local", used: 0, total: 0 }, setPin: noop },
    },
    new NativeInfoActions(),
    t,
  )!;
  const runsOn = section.rows.find((row) => row.id === "runsOn")!;
  expect(runsOn.menu!.map((item) => item.label)).toEqual([
    t("hybrid.pin.local"),
    t("hybrid.mode.hybrid"),
    t("hybrid.pin.cloud"),
  ]);
});

for (const look of ["rows", "segmented"] as const)
  test(`the place control (${look}) lists This Mac, Auto, Cloud`, () => {
    const page = parse(<PlaceControl place={PLACES.local} look={look} onMode={noop} />);
    const modes = [...page.querySelectorAll("[data-testid^='place-']")].map((button) =>
      button.getAttribute("data-testid"),
    );
    expect(modes).toEqual(["place-local", "place-auto", "place-cloud"]);
  });
