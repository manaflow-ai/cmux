// l10n-allow-file: gallery fixtures (public-safe sample disk reports) and gallery-only captions.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import { DiskBar, type DiskBarVariant } from "./DiskBar";
import type { CloudDiskBar } from "./ops";
import table from "./generated/strings.json";

type Props = { variant: DiskBarVariant };

type Segment = CloudDiskBar["segments"][number];
const GIB = 1024 ** 3;
const segment = (kind: Segment["kind"], gb: number, width: number): Segment => ({
  kind,
  bytes: Math.round(gb * GIB),
  gb,
  width,
});

/**
 * The views cmux-cloud-disk's `view()` answers for these reports (its tests.rs asserts the same
 * labels, and its widths come from the same largest-remainder split): the gallery draws them as
 * the page would.
 */
const split = (
  total: number,
  [system, project, caches]: [number, number, number],
  free: number,
  widths: [number, number, number, number],
  state: CloudDiskBar["state"] = "ok",
): CloudDiskBar => {
  const used = Math.round((system + project + caches) * 10) / 10;
  return {
    state,
    total_gb: total,
    used_gb: used,
    free_gb: free,
    segments: [
      segment("system", system, widths[0]),
      segment("project", project, widths[1]),
      segment("caches", caches, widths[2]),
      segment("free", free, widths[3]),
    ],
    label: `${used} / ${total} GB`,
    text: `${used} of ${total} GB, ${free} free`,
  };
};

const STATES: ReadonlyArray<{ caption: string; name: string; bar: CloudDiskBar }> = [
  { caption: "Fresh: 5.3 of 20 GB", name: "fresh-agent", bar: split(20, [5.2, 0.1, 0], 14.7, [260, 10, 0, 730]) },
  { caption: "A day in: 13 of 20 GB", name: "day-one", bar: split(20, [5.3, 4.5, 3.2], 7, [265, 225, 160, 350]) },
  {
    caption: "Almost full: 18.6 of 20 GB (under 2 GB free)",
    name: "busy-build",
    bar: split(20, [5.4, 9, 4.2], 1.4, [270, 450, 210, 70], "almost_full"),
  },
  {
    caption: "Just grown: 20.5 of 24 GB",
    name: "grown-disk",
    bar: split(24, [5.4, 10, 5.1], 3.5, [225, 417, 212, 146]),
  },
  {
    caption: "Numbers absent (older guest): the allocation alone, as today",
    name: "older-guest",
    bar: { state: "allocated", total_gb: 20, segments: [], label: "20 GB", text: "20 GB" },
  },
];

function DiskBarGallery({ variant }: Props) {
  const [strings] = useState(() => createStrings(table));
  return (
    <section className="cloud-detail-section" data-gallery-capture="">
      {STATES.map(({ caption, name, bar }) => (
        <div key={name} className="cloud-disk-bar-gallery-state">
          <div className="cloud-machine-subtitle">{caption}</div>
          <div className="cloud-muted">Machine row</div>
          <div>
            <span className="cloud-machine-title">{name}</span>{" "}
            <span className="cloud-machine-disk">
              <DiskBar bar={bar} strings={strings} variant={variant} compact />
            </span>
          </div>
          <div className="cloud-muted">Machine detail</div>
          <div className="cloud-disk-health">
            <DiskBar bar={bar} strings={strings} variant={variant} />
          </div>
        </div>
      ))}
    </section>
  );
}

export default componentEntry<Props>({
  id: "cloud.disk-bar",
  title: "Cloud disk bar",
  area: "Pages",
  height: 640,
  widths: { narrow: 360, normal: 700, wide: 1000 },
  covers: ["pages/cloud/DiskBar.tsx"],
  load: async () => DiskBarGallery,
  styles: () => Promise.all([import("../shared/pageBase.css"), import("./styles.css")]),
  variants: {
    segmented: {
      note: "(a) A bar of system, project and caches with the free rest, and the numbers: the shipped form.",
      props: { variant: "segmented" },
    },
    single: {
      note: "(b) One used colour; the split on hover and in the expanded detail.",
      props: { variant: "single" },
    },
    text: {
      note: "(c) Text only: 13.2 of 20 GB, 6.8 free.",
      props: { variant: "text" },
    },
  },
});
