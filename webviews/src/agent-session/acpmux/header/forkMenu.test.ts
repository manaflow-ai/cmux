import { expect, test } from "bun:test";
import { agentForkRows, forkMenuRows } from "./forkMenu";
import { FORK_ICON } from "../icons/forkIcon";

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

test("another agent is Fork to Agent… beside Fork where the chat forks onto it, Hand off to… where it cannot", () => {
  const targets = [
    { id: "codex", name: "Codex" },
    { id: "opencode", name: "OpenCode" },
  ];
  const picked: string[] = [];
  const forks = agentForkRows(
    targets,
    { forks: true, disabled: false, handOffLabel: "Hand off to…" },
    (h) => picked.push(h),
    (key) => key,
  );
  expect(forks.handOff).toEqual([]);
  const row = forks.fork[0];
  if (!row || row === "separator") throw new Error("missing row");
  expect(row.label).toBe("chatMenu.forkToAgent");
  expect(row.icon).toBe(FORK_ICON);
  // The palette's Continue In… still opens it by its key.
  expect(row.key).toBe("continue");
  expect(row.children?.map((child) => child.label)).toEqual(["Codex", "OpenCode"]);
  row.children?.[0]?.onSelect();
  expect(picked).toEqual(["codex"]);

  const handsOff = agentForkRows(
    targets,
    { forks: false, disabled: true, handOffLabel: "Hand off to…" },
    () => {},
    (key) => key,
  );
  expect(handsOff.fork).toEqual([]);
  const review = handsOff.handOff[0];
  if (!review || review === "separator") throw new Error("missing row");
  expect(review.label).toBe("Hand off to…");
  expect(review.icon).toBe("agent.handoff");
  expect(review.disabled).toBe(true);

  expect(
    agentForkRows(
      [],
      { forks: true, disabled: false, handOffLabel: "" },
      () => {},
      (key) => key,
    ),
  ).toEqual({
    fork: [],
    handOff: [],
  });
});
