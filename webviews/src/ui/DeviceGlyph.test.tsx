// Every device kind draws a glyph, and every machine surface draws it from the one shared component
// (Leo 2026-11-14: "nicer icons ... across all the remote related areas").
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { DeviceGlyph } from "./DeviceGlyph";
import { DEVICE_GLYPH_PATHS } from "./deviceGlyphPaths";
import { DEVICE_KINDS, DEVICE_SYMBOLS, deviceKindsFromStatus, noteDeviceKinds, resetDeviceKinds } from "./deviceKinds";
import { EnvironmentIcon } from "../agent-session/acpmux/EnvironmentPicker";

afterEach(() => resetDeviceKinds());

test("every kind in the Rust table has its symbol's paths", () => {
  expect(DEVICE_KINDS.length).toBe(11);
  for (const kind of DEVICE_KINDS) {
    const layers = DEVICE_GLYPH_PATHS[DEVICE_SYMBOLS[kind]];
    expect(layers?.length, kind).toBeGreaterThan(0);
    const markup = renderToStaticMarkup(createElement(DeviceGlyph, { kind }));
    expect(markup).toContain(`data-device="${kind}"`);
    expect(markup).toContain("<path");
  }
});

test("a status read names this machine and each peer", () => {
  const status = {
    device: "mac-mini",
    peers: [
      { name: "gpu-box", health: { device: "linux-server" } },
      { name: "old", health: {} },
      { name: "odd", health: { device: "toaster" } },
      { name: "vm", transport: "wss", health: { device: "linux-server" } },
      { name: "direct-vm", url: "wss://relay.example/vm", health: { device: "linux-server" } },
    ],
  };
  expect(deviceKindsFromStatus(status)).toEqual({
    local: "mac-mini",
    peers: { "gpu-box": "linux-server", vm: "cloud", "direct-vm": "cloud" },
  });
});

test("the location picker draws each machine's reported kind", () => {
  const icon = (kind: "local" | "ssh" | "cloud", name?: string) =>
    renderToStaticMarkup(createElement(EnvironmentIcon, name ? { kind, name } : { kind }));
  // Before the daemon says: This Mac is the MacBook it always was, SSH keeps its terminal glyph.
  expect(icon("local")).toContain('data-device="macbook"');
  expect(icon("ssh", "gpu-box")).not.toContain("data-device");
  noteDeviceKinds({ device: "mac-mini", peers: [{ name: "gpu-box", health: { device: "linux-server" } }] });
  expect(icon("local")).toContain('data-device="mac-mini"');
  expect(icon("ssh", "gpu-box")).toContain('data-device="linux-server"');
  // An SSH icon with no machine named (a saved environment, an action row) never takes this Mac's.
  expect(icon("ssh")).not.toContain("data-device");
  // The box keeps its size: this Mac's wide MacBook box, every other machine the square one.
  expect(icon("local")).toContain("acpmux-macbook-icon");
  expect(icon("ssh", "gpu-box")).not.toContain("acpmux-macbook-icon");
  // A Cloud machine keeps its own cloud icon, whatever its VM reports.
  const cloudBefore = icon("cloud", "vm");
  noteDeviceKinds({ peers: [{ name: "vm", health: { device: "linux-server" } }] });
  expect(icon("cloud", "vm")).toBe(cloudBefore);
  expect(cloudBefore).not.toContain("data-device");
  // A later read without kinds keeps what was said.
  noteDeviceKinds({ peers: [] });
  expect(icon("local")).toContain('data-device="mac-mini"');
});

/// The web surfaces that draw a machine. Each draws its glyph from ui/DeviceGlyph, never a copy.
const SURFACES = [
  "agent-session/acpmux/EnvironmentPicker.tsx",
  "agent-session/acpmux/ComposerContext.tsx",
  "agent-session/acpmux/ProjectChooser.tsx",
];

test("every machine surface uses the shared device glyph", () => {
  const src = path.resolve(import.meta.dir, "..");
  for (const file of SURFACES) {
    const text = readFileSync(path.join(src, file), "utf8");
    expect(/from "(\.\.\/)+ui\/DeviceGlyph"/.test(text), file).toBe(true);
    expect(/<(DeviceGlyph|DeviceGlyphShapes|MachineGlyph)\b/.test(text), file).toBe(true);
  }
});
