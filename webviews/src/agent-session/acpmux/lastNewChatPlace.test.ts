import { expect, test } from "bun:test";
import {
  lastNewChatPlace,
  pickedRunLocation,
  pickedStartMachine,
  placeOfRunMode,
  rememberNewChatPlace,
  type PlaceStore,
} from "./lastNewChatPlace";
import { newChatRunLocation } from "./runLocationDefault";

const store = (): PlaceStore & { items: Map<string, string> } => {
  const items = new Map<string, string>();
  return { items, getItem: (name) => items.get(name) ?? null, setItem: (name, value) => void items.set(name, value) };
};

// cmux#46019: Cloud or a machine picked for one workspace's new chat is where the next workspace's starts.
test("the last pick is read back by the next page, whichever place it was", () => {
  const kept = store();
  expect(lastNewChatPlace(kept)).toBeUndefined();
  rememberNewChatPlace({ kind: "cloud" }, kept);
  expect(lastNewChatPlace(kept)).toEqual({ kind: "cloud" });
  rememberNewChatPlace({ kind: "machine", peer: "build-box" }, kept);
  expect(lastNewChatPlace(kept)).toEqual({ kind: "machine", peer: "build-box" });
  rememberNewChatPlace({ kind: "local" }, kept);
  expect(lastNewChatPlace(kept)).toEqual({ kind: "local" });
});

test("a kept value this build can't read, or no storage at all, is no pick", () => {
  const kept = store();
  for (const raw of ["not json", "42", '{"kind":"mars"}', '{"kind":"machine"}', '{"kind":"machine","peer":""}']) {
    kept.items.set("cmux.agentPane.lastNewChatPlace", raw);
    expect(lastNewChatPlace(kept)).toBeUndefined();
  }
  const refusing: PlaceStore = {
    getItem: () => {
      throw new Error("denied");
    },
    setItem: () => {
      throw new Error("full");
    },
  };
  expect(lastNewChatPlace(refusing)).toBeUndefined();
  expect(() => rememberNewChatPlace({ kind: "cloud" }, refusing)).not.toThrow();
  expect(lastNewChatPlace(undefined)).toBeUndefined();
});

test("a run mode pick names Cloud or This Mac; Sandboxed names no place", () => {
  expect(placeOfRunMode("cloud")).toEqual({ kind: "cloud" });
  expect(placeOfRunMode("persistent")).toEqual({ kind: "local" });
  expect(placeOfRunMode("sandboxed")).toBeUndefined();
});

test("the last pick decides Cloud over the folder's history; Settings' Cloud still wins", () => {
  // Picked Cloud: a folder with no chats, or one whose newest chat ran here, still starts on Cloud.
  expect(newChatRunLocation("local", undefined, pickedRunLocation({ kind: "cloud" }))).toBe("cloud");
  expect(newChatRunLocation("local", "local", pickedRunLocation({ kind: "cloud" }))).toBe("cloud");
  // Picked This Mac or another machine: not Cloud, whatever the folder's history says.
  expect(newChatRunLocation("local", "cloud", pickedRunLocation({ kind: "local" }))).toBe("local");
  expect(newChatRunLocation("local", "cloud", pickedRunLocation({ kind: "machine", peer: "m" }))).toBe("local");
  // Nothing picked yet: the folder's history, as before.
  expect(newChatRunLocation("local", "cloud", pickedRunLocation(undefined))).toBe("cloud");
  expect(newChatRunLocation("local", undefined, pickedRunLocation(undefined))).toBeUndefined();
  // Settings' Start New Chats In: Cloud.
  expect(newChatRunLocation("cloud", undefined, pickedRunLocation({ kind: "local" }))).toBe("cloud");
});

test("a new page starts on the picked machine only while acpmux lists it connected and the chat is not Cloud", () => {
  const machine = { kind: "machine", peer: "build-box" } as const;
  expect(pickedStartMachine(machine, "local", ["build-box"])).toBe("build-box");
  expect(pickedStartMachine(machine, undefined, ["build-box"], { "build-box": true })).toBe("build-box");
  expect(pickedStartMachine(machine, "local", [])).toBeUndefined();
  expect(pickedStartMachine(machine, "local", undefined)).toBeUndefined();
  expect(pickedStartMachine(machine, "local", ["build-box"], { "build-box": false })).toBeUndefined();
  expect(pickedStartMachine(machine, "cloud", ["build-box"])).toBeUndefined();
  expect(pickedStartMachine({ kind: "cloud" }, undefined, ["build-box"])).toBeUndefined();
  expect(pickedStartMachine({ kind: "local" }, undefined, ["build-box"])).toBeUndefined();
});

// Auto (autoWhereModel.ts) is kept as itself and names no run location: the daemon picks on Send.
test("Auto is remembered as Auto and leaves the run location to the folder's default", () => {
  const kept = store();
  rememberNewChatPlace({ kind: "auto" }, kept);
  expect(lastNewChatPlace(kept)).toEqual({ kind: "auto" });
  expect(pickedRunLocation({ kind: "auto" })).toBeUndefined();
});
