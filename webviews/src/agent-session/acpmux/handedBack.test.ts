import { afterEach, expect, test } from "vitest";
import { noteHandedBack, onHandedBackRecorded, promptRecorded, withoutHandedBack } from "./handedBack";

const heard: string[] = [];
let stop = onHandedBackRecorded((back) => heard.push(back.text));
afterEach(() => {
  heard.length = 0;
});

test("a timed-out prompt that acpmux records late leaves the composer once", () => {
  noteHandedBack("p1", { text: "fix the toolbar", attachments: [] });
  promptRecorded("p1");
  promptRecorded("p1");
  expect(heard).toEqual(["fix the toolbar"]);
});

test("a prompt nobody handed back is not announced", () => {
  promptRecorded("never-handed-back");
  expect(heard).toEqual([]);
  stop();
  stop = onHandedBackRecorded(() => undefined);
});

test("only the replayed words leave the draft; the next message stays", () => {
  expect(withoutHandedBack("old one\n\nnew one", "old one")).toBe("new one");
  expect(withoutHandedBack("a\n\nold one\n\nb", "old one")).toBe("a\n\nb");
  expect(withoutHandedBack("old one", "old one")).toBe("");
});

test("an edited copy is the person's own and stays", () => {
  expect(withoutHandedBack("old one, more", "old two")).toBe("old one, more");
});
