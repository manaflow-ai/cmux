import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { DiskHealthSummary } from "./DiskHealth";
import { setExperimentSwitches } from "../../experiments/switches";
import type { Strings } from "../shared/i18n";

const strings: Strings = {
  language: "en",
  t: (key) =>
    ({
      "unit.gigabytes": "{value} GB",
      "disk.dataUnavailable": "Disk data unavailable",
      "disk.dataStale": "Disk data is stale",
      "disk.lowSpace": "Low disk space",
      "disk.free": "Free",
      "disk.used": "Used",
      "disk.floor": "Floor",
      "disk.topUsers": "Top users",
      "field.disk": "Disk",
    })[key] ?? key,
  format: (key, ...args) => key.replace("%@", args[0] ?? ""),
};

test("the compact summary exposes free and used capacity", () => {
  const html = renderToStaticMarkup(
    <DiskHealthSummary
      compact
      strings={strings}
      health={{
        state: "healthy",
        free_mb: 8_192,
        used_mb: 57_344,
        total_mb: 65_536,
        floor_mb: 4_096,
        top_users: [],
        observed_at: Date.now(),
      }}
    />,
  );
  expect(html).toContain("Free 8 GB");
  expect(html).toContain("Used 56 GB / 64 GB");
});

test("the full summary calls out a low floor and top users", () => {
  const html = renderToStaticMarkup(
    <DiskHealthSummary
      strings={strings}
      health={{
        state: "warning",
        free_mb: 4_096,
        used_mb: 61_440,
        total_mb: 65_536,
        floor_mb: 4_096,
        top_users: [{ path: "/var/lib/docker", used_mb: 40_960 }],
        observed_at: Date.now(),
      }}
    />,
  );
  expect(html).toContain("Low disk space");
  expect(html).toContain("Floor 4 GB");
  expect(html).toContain("/var/lib/docker");
});

test("the disk bar draws only with experiments.cloudDiskBar on, even where the health is unknown", () => {
  // What cmux-platform writes from the guest's sample: sizes and the split, no floor or top users.
  const health = {
    state: "unknown",
    free_mb: 10_240,
    used_mb: 10_240,
    total_mb: 20_480,
    observed_at: Date.now(),
    bar: {
      state: "ok",
      total_gb: 20,
      used_gb: 10,
      free_gb: 10,
      label: "10 / 20 GB",
      text: "10 of 20 GB, 10 free",
      segments: [
        { kind: "system", bytes: 4 << 30, gb: 4, width: 200 },
        { kind: "project", bytes: 5 << 30, gb: 5, width: 250 },
        { kind: "caches", bytes: 1 << 30, gb: 1, width: 50 },
        { kind: "free", bytes: 10 << 30, gb: 10, width: 500 },
      ],
    },
  } as unknown as Parameters<typeof DiskHealthSummary>[0]["health"];
  const render = () => renderToStaticMarkup(<DiskHealthSummary compact strings={strings} health={health} />);
  setExperimentSwitches({});
  expect(render()).toContain("Disk data unavailable");
  expect(render()).not.toContain("cloud-disk-bar");
  setExperimentSwitches({ cloudDiskBar: true });
  try {
    expect(render()).toContain("cloud-disk-bar-caches");
    expect(render()).not.toContain("Disk data unavailable");
  } finally {
    setExperimentSwitches({});
  }
});
