// l10n-allow-file: fixture text (the CLI's own English notes and messages), not shipped UI.
// Settings > Design System as the host answers it (`cmux --json ext design --show --scene`):
// fixtures/design-system-page.json holds the scenes the SDK's DesignSystemView draws for cmux's own
// system and for one built on design.json with two values cmux changed since its recorded base
// (cmux-app-host/js/test/design.test.ts records it, CMUX_RECORD_DESIGN_SYSTEM=1).
import type { SceneOp } from "../../apps/scene/store";
import page from "./fixtures/design-system-page.json";
import type { DesignSystemState } from "./ops";

const scenes = page as unknown as Record<"cmux" | "changed", SceneOp[]>;
const person = "/Users/me/.config/cmux/design.json";

export type MockDesignSystem = "cmux" | "changed" | "unreadable";

export function mockDesignSystem(state: MockDesignSystem = "cmux"): DesignSystemState {
  const cmux = { kind: "cmux", file: "cmux", applied: true };
  if (state === "cmux")
    return {
      layers: [cmux],
      changed: [],
      design: [],
      note: "cmux's own design system; add design.json beside your settings to make it yours",
      scene: scenes.cmux,
    };
  const changed = [
    {
      key: "type.numeral",
      kept: false,
      file: person,
      text: "type.numeral: cmux changed it from 32 pt semibold to 34 pt semibold (you get the new one)",
    },
    {
      key: "space",
      kept: true,
      file: person,
      text: "space: cmux changed it from 0 2 4 8 16 40 to 0 2 4 6 8 12 16 20 24 32 48 (yours holds)",
    },
  ];
  if (state === "changed")
    return {
      layers: [cmux, { kind: "person", file: person, applied: true }],
      changed,
      design: [],
      note: "Built on cmux, then design.json",
      scene: scenes.changed,
    };
  return {
    layers: [
      cmux,
      { kind: "theme", file: "theme dusk", applied: false },
      { kind: "person", file: person, applied: true },
    ],
    changed,
    design: [
      {
        check: "system",
        message:
          "theme dusk: type.body.size is 99 pt, past the largest role cmux allows (40 pt); the layers under it still apply",
        fix: "give body a size from 9 to 40 pt",
      },
    ],
    note: "Built on cmux, then design.json",
    scene: scenes.changed,
  };
}
