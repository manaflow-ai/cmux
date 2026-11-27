// Settings > Agent Chat > Effort Chip (`agentPane.display.effortChip`, chatDisplay.ts): the
// composer look decides where the effort shows unless a look (the Codex app profile) joins it to
// the model chip (customize-app-profiles, ask-aad661801e).
import { afterEach, expect, test } from "bun:test";
import { EFFORT_CHIP_KEY, effortChipSetting, resetChatDisplayForTests, setChatDisplay } from "./chatDisplay";

afterEach(() => resetChatDisplayForTests());

test("Effort Chip is auto until a look joins it to the model chip", () => {
  expect(effortChipSetting()).toBe("auto");
  setChatDisplay({ [EFFORT_CHIP_KEY]: "joined" });
  expect(effortChipSetting()).toBe("joined");
});

test("an unknown Effort Chip value reads as auto", () => {
  setChatDisplay({ [EFFORT_CHIP_KEY]: "joined" });
  setChatDisplay({ [EFFORT_CHIP_KEY]: "split" });
  expect(effortChipSetting()).toBe("auto");
  setChatDisplay({ [EFFORT_CHIP_KEY]: true });
  expect(effortChipSetting()).toBe("auto");
});
