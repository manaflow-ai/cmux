import { expect, test } from "bun:test";
import { forkMenuRows } from "./forkMenu";

test("header Fork is immediate, with destination selection in its own row", () => {
  let forks = 0;
  const destinations: number[] = [];
  const rows = forkMenuRows(
    42,
    () => {
      forks++;
    },
    (key) => key,
    (seq) => {
      destinations.push(seq);
      return true;
    },
  );
  const primary = rows[0],
    secondary = rows[1];
  if (!primary || primary === "separator" || !secondary || secondary === "separator") throw new Error("missing rows");
  expect(primary.children).toBeUndefined();
  // The ··· menu's Fork takes no letter: typing "fo" there is its typeahead, never a fork. The title
  // menu adds its own F (App.tsx), as #25661 settled.
  expect(primary.accelerator).toBeUndefined();
  primary.onSelect?.();
  expect(forks).toBe(1);
  expect(destinations).toEqual([]);
  secondary.onSelect?.();
  expect(destinations).toEqual([42]);
  expect(forks).toBe(1);
});
