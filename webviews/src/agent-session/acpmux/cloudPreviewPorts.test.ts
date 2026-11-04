import { beforeEach, describe, expect, test } from "bun:test";
import {
  addCloudPreviewPort,
  cloudPreviewPorts,
  resetCloudPreviewPorts,
  seedCloudPreviewPorts,
} from "./cloudPreviewPorts";

describe("Cloud preview port cards", () => {
  beforeEach(() => resetCloudPreviewPorts());

  test("creates one card per new port", () => {
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(true);
    expect(addCloudPreviewPort({ port: 3001, process: "node" })).toBe(true);
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([
      { port: 3000, process: "vite" },
      { port: 3001, process: "node" },
    ]);
  });

  test("does not add a card for a port already known by the machine", () => {
    seedCloudPreviewPorts([{ port: 3000, process: "vite" }]);
    expect(addCloudPreviewPort({ port: 3000, process: "vite" })).toBe(false);
    expect(cloudPreviewPorts()).toEqual([]);
  });
});
