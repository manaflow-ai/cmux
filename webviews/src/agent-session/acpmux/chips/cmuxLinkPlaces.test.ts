// The host's places for cmux link chips: a whole push replaces them, a rename push (an agent's title
// spinner, several a second) updates only the places it names (Lawrence 2026-11-19: the whole list on
// every rename kept the New Tab page's frames at 100-977 ms with ~1,000 workspaces).
import { expect, test } from "bun:test";
import { linkPlace, linkPlacesVersion, setLinkPlaces, subscribeLinkPlaces, updateLinkPlaces } from "./cmuxLinkPlaces";

const id = (kind: string, n: number) => `${kind}_${n.toString(16).padStart(32, "0")}`;
const whole = (count: number) =>
  Array.from({ length: count }, (_, n) => [
    { id: id("ws", n), kind: "workspace", title: `w${n}` },
    { id: id("tab", n), kind: "tab", title: `shell ${n}`, workspace: `w${n}` },
  ]).flat();

test("a rename push updates the places it names and keeps every other one as it was", () => {
  setLinkPlaces(whole(1000));
  const kept = linkPlace(id("tab", 2));
  const version = linkPlacesVersion();
  let heard = 0;
  const off = subscribeLinkPlaces(() => (heard += 1));
  updateLinkPlaces([{ id: id("tab", 417), kind: "tab", title: "⠙ Working", workspace: "w417" }]);
  off();
  expect(linkPlace(id("tab", 417))?.title).toBe("⠙ Working");
  expect(linkPlace(id("tab", 2))).toBe(kept);
  expect(linkPlace(id("ws", 999))?.title).toBe("w999");
  expect(linkPlacesVersion()).toBe(version + 1);
  expect(heard).toBe(1);
});

test("a rename push of a place the list does not hold, or of no change, wakes nobody", () => {
  setLinkPlaces(whole(3));
  const version = linkPlacesVersion();
  let heard = 0;
  const off = subscribeLinkPlaces(() => (heard += 1));
  updateLinkPlaces([{ id: id("tab", 4096), kind: "tab", title: "past the cap" }]);
  updateLinkPlaces([{ id: id("tab", 1), kind: "tab", title: "shell 1", workspace: "w1" }]);
  updateLinkPlaces([{ id: "not-an-id", kind: "tab", title: "x" }, "junk"]);
  updateLinkPlaces("junk");
  off();
  expect(linkPlace(id("tab", 4096))).toBeUndefined();
  expect(linkPlacesVersion()).toBe(version);
  expect(heard).toBe(0);
});
