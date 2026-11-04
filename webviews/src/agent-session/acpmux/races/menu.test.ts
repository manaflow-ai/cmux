import { expect, test } from "bun:test";
import { raceToolsMenu } from "./menu";
import type { Translate } from "../i18n";

const t: Translate = (key) => key;
test("race and inspector share the existing utility slot without adding a top-level menu row", () => {
  const opened: string[] = [];
  const item = raceToolsMenu(
    () => opened.push("inspector"),
    () => opened.push("race"),
    t,
  );
  if (item === "separator") throw new Error("expected tools menu");
  expect(item.key).toBe("tools");
  expect(item.children?.map((child) => child.key)).toEqual(["race", "inspector"]);
  item.children?.[0]?.onSelect();
  item.children?.[1]?.onSelect();
  expect(opened).toEqual(["race", "inspector"]);
});

test("without an attached race-capable client the inspector stays a direct action", () => {
  let inspected = false;
  const item = raceToolsMenu(
    () => {
      inspected = true;
    },
    undefined,
    t,
  );
  if (item === "separator") throw new Error("expected inspector");
  expect(item.key).toBe("inspector");
  expect(item.children).toBeUndefined();
  item.onSelect?.();
  expect(inspected).toBe(true);
});
