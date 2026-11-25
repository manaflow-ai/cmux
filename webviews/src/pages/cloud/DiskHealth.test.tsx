import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { DiskHealthSummary } from "./DiskHealth";
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
