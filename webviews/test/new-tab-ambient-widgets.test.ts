// The New Tab page's ambient widgets (`tabs.newTabWidgets.weather|machines`, newtab/ambient.ts):
// the handshake's weather reading is validated, dimmed once older than its 30-minute refresh, and
// the machines are this Mac, acpmux's peers (online) and older chats' hosts (offline), each with a
// color that stays the same for its name. Every layout shows them when they are on.
import { expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { AmbientWidgets, pressMachine } from "../src/agent-session/acpmux/newtab/AmbientWidgets";
import { machineColor } from "../src/agent-session/acpmux/machineColor";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";
import {
  WEATHER_MAX_AGE_MS,
  degrees,
  machinePress,
  newTabMachines,
  parseWeather,
  weatherGlyph,
  weatherIsStale,
} from "../src/agent-session/acpmux/newtab/ambient";
import { parsePageWidgets, shownPageWidgets } from "../src/agent-session/acpmux/newtab/pageWidgets";

const reading = { place: "Berlin", temperature: 18.4, high: 22.1, low: 11.6, code: 2, unit: "celsius", readAt: 1000 };

test("the handshake carries a valid weather reading and drops a malformed one", () => {
  expect(newTabHost({ newTab: { weather: reading } })?.weather).toEqual(reading as never);
  expect(parseWeather({ ...reading, unit: "kelvin" })).toBeUndefined();
  expect(parseWeather({ ...reading, temperature: "hot" })).toBeUndefined();
  expect(parseWeather({ ...reading, place: "" })).toBeUndefined();
  expect(newTabHost({ newTab: {} })?.weather).toBeUndefined();
});

test("a reading is dimmed once it is older than its refresh", () => {
  const weather = parseWeather(reading)!;
  expect(weatherIsStale(weather, 1000 + WEATHER_MAX_AGE_MS - 1)).toBe(false);
  expect(weatherIsStale(weather, 1000 + WEATHER_MAX_AGE_MS)).toBe(true);
});

test("temperatures round to whole degrees and codes map to glyphs", () => {
  expect(degrees(18.4)).toBe("18°");
  expect(degrees(-0.4)).toBe("0°");
  expect(degrees(-3.6)).toBe("-4°");
  expect(weatherGlyph(0)).toBe("☀︎");
  expect(weatherGlyph(63)).toBe("☂︎");
  expect(weatherGlyph(73)).toBe("❄︎");
  expect(weatherGlyph(95)).toBe("⚡︎");
});

test("machines: this Mac, then peers online, then older chats' hosts offline", () => {
  const machines = newTabMachines(
    {
      peers: ["cosmic-gray", "cloud-a"],
      sessions: [
        { sessionId: "1", peer: "cosmic-gray", host: "cosmic-gray" },
        { sessionId: "2", hostKind: "cloud", host: "cloud-old" },
        { sessionId: "3", peer: "huge-blue", host: "huge-blue" },
      ] as never,
    },
    { "cosmic-gray": "ssh", "cloud-a": "cloud" },
    "air-blue",
  );
  expect(machines.map((m) => [m.id, m.kind, m.online])).toEqual([
    ["local", "local", true],
    ["cosmic-gray", "ssh", true],
    ["cloud-a", "cloud", true],
    ["cloud-old", "cloud", false],
    ["huge-blue", "cloud", false],
  ]);
  expect(machines[0]!.label).toBe("air-blue");
});

test("another machine wears its identity color, this Mac none", () => {
  const machines = newTabMachines({ sessions: [], peers: ["cosmic-gray"] }, {}, "air-blue");
  expect(machines[0]!.color).toBeUndefined();
  expect(machines[1]!.color).toBe(machineColor("cosmic-gray"));
});

test("weather and machines are widgets on every layout, the old layouts keep what they drew", () => {
  expect(parsePageWidgets(["weather", "machines", "nope"])).toEqual(["weather", "machines"]);
  expect([...shownPageWidgets("minimal", ["weather"])]).toEqual(["weather"]);
  const cards = shownPageWidgets("cards", ["greeting", "weather", "machines"]);
  expect(cards.has("weather") && cards.has("machines")).toBe(true);
  expect(cards.has("greeting")).toBe(false);
  expect(shownPageWidgets("cards").has("weather")).toBe(false);
  expect(shownPageWidgets("cards").has("chats")).toBe(true);
});

// Leo, 2026-10-26: "in the new tab page ... we should have buttons for connected cloud machines? and
// adding new stuff. the dropdown should show the states of stuff when you've done the acp things".
test("each peer carries its live link: green connected, the spinner on its way, red down", () => {
  const machines = newTabMachines(
    {
      sessions: [],
      peers: ["build-box", "gpu-box", "lab-mini", "slow-box"],
      peerConnected: { "build-box": true, "gpu-box": false, "lab-mini": false, "slow-box": true },
      peerStates: {
        "build-box": "connected",
        "gpu-box": "reconnecting",
        "lab-mini": "offline",
        "slow-box": "degraded",
      },
    },
    { "build-box": "ssh", "gpu-box": "ssh", "lab-mini": "ssh", "slow-box": "ssh" },
    "air-blue",
  );
  expect(machines.map((m) => [m.id, m.link, m.online, m.listed])).toEqual([
    ["local", undefined, true, undefined],
    ["build-box", "connected", true, true],
    ["gpu-box", "connecting", false, true],
    ["lab-mini", "offline", false, true],
    // A degraded link has not finished its handshake: on its way, never green, no chat yet.
    ["slow-box", "connecting", false, true],
  ]);
});

test("the account's Cloud machines acpmux does not list show with their stage", () => {
  const machines = newTabMachines(
    { sessions: [{ sessionId: "1", hostKind: "cloud", host: "atlas-web" }] as never, peers: [] },
    {},
    "air-blue",
    [
      { id: "m-1", name: "atlas-web", stage: "paused" },
      { id: "m-2", name: "eval-box", stage: "booting" },
      { id: "m-3", name: "ready-box", stage: "ready" },
    ],
  );
  // The old Cloud chat's host gives way to the account's machine of its name, which knows its stage.
  expect(machines.map((m) => [m.label, m.link, m.cloudMachine?.stage])).toEqual([
    ["air-blue", undefined, undefined],
    ["atlas-web", "paused", "paused"],
    ["eval-box", "connecting", "booting"],
    ["ready-box", undefined, "ready"],
  ]);
});

test("a press picks the machine, reconnects a down peer as it picks it, and resumes a Cloud machine", () => {
  const calls: string[] = [];
  const buttons = {
    current: "local",
    onPick: (id: string) => calls.push(`pick ${id}`),
    onReconnect: (id: string) => calls.push(`reconnect ${id}`),
    onCloudMachine: (machine: { id: string }) => calls.push(`cloud ${machine.id}`),
  };
  const machines = newTabMachines(
    {
      sessions: [{ sessionId: "1", peer: "old-box", host: "old-box" }] as never,
      peers: ["build-box", "lab-mini"],
      peerStates: { "build-box": "connected", "lab-mini": "offline" },
    },
    { "build-box": "ssh", "lab-mini": "ssh" },
    "air-blue",
    [{ id: "m-1", name: "atlas-web", stage: "paused" }],
  );
  const byId = (id: string) => machines.find((m) => m.id === id)!;
  expect(machinePress(byId("old-box"))).toBe("none");
  for (const id of ["local", "build-box", "lab-mini", "cloud-machine:m-1", "old-box"]) pressMachine(byId(id), buttons);
  expect(calls).toEqual(["pick local", "pick build-box", "reconnect lab-mini", "pick lab-mini", "cloud m-1"]);
});

test("the buttons show each link, the pick pressed, and Add Machine… last", () => {
  const html = renderToStaticMarkup(
    createElement(AmbientWidgets, {
      machines: true,
      snapshot: {
        sessions: [],
        peers: ["build-box", "gpu-box"],
        peerKinds: { "build-box": "ssh", "gpu-box": "ssh" },
        peerStates: { "build-box": "connected", "gpu-box": "reconnecting" },
      },
      localName: "air-blue",
      now: 0,
      cloudMachines: [],
      buttons: { current: "build-box", onPick() {}, onReconnect() {}, onCloudMachine() {}, onAddMachine() {} },
    }),
  );
  expect(html).toContain('data-machine="build-box"');
  expect(html).toMatch(/data-machine="build-box"[^>]*aria-pressed="true"/);
  expect(html).toMatch(/data-machine="local"[^>]*aria-pressed="false"/);
  expect(html).toContain('data-link="connected"');
  // On its way: the turning ring, never a pulsing dot.
  expect(html).toMatch(/data-link="connecting"[^>]*role="img"[^>]*><svg/);
  expect(html.lastIndexOf("data-machine-add")).toBeGreaterThan(html.lastIndexOf("data-machine="));
});
