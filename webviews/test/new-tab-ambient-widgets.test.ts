// The New Tab page's ambient widgets (`tabs.newTabWidgets.weather|machines`, newtab/ambient.ts):
// the handshake's weather reading is validated, dimmed once older than its 30-minute refresh, and
// the machines are this Mac, acpmux's peers (online) and older chats' hosts (offline), each with a
// color that stays the same for its name. Every layout shows them when they are on.
import { expect, test } from "bun:test";
import { machineColor } from "../src/agent-session/acpmux/machineColor";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";
import {
  WEATHER_MAX_AGE_MS,
  degrees,
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
