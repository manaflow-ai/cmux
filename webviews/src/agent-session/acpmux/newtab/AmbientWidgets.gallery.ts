// l10n-allow-file: gallery fixture machine names, not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AmbientWidgets } from "./AmbientWidgets";

const base: ComponentProps<typeof AmbientWidgets> = {
  machines: true,
  localName: "Studio Mac",
  now: 0,
  snapshot: { sessions: [], peers: [] },
  onPickMachine: () => undefined,
  onAddMachine: () => undefined,
};

export default componentEntry<ComponentProps<typeof AmbientWidgets>>({
  id: "agent-pane.new-tab-machines",
  title: "New Tab machines",
  area: "New Tab",
  pane: true,
  load: () => import("./AmbientWidgets").then((module) => module.AmbientWidgets),
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 120,
  covers: ["agent-session/acpmux/newtab/AmbientWidgets.tsx#AmbientWidgets"],
  variants: {
    empty: { note: "Quiet cloud trial action beside this Mac; no banner.", props: base },
    connected: {
      note: "Chosen: plain connected-machine buttons, explicit state, and one Add action; a paused native cloud machine opens Resume.",
      props: {
        ...base,
        snapshot: {
          sessions: [],
          peers: ["build-box"],
          peerKinds: { "build-box": "ssh" },
          peerStatus: { "build-box": { state: "connected", connected: true } },
          machines: [
            { id: "vm-demo", label: "Cloud dev", kind: "cloud", native: true, status: "paused", connected: false },
          ],
        },
      },
    },
    attention: {
      note: "Connecting and unreachable machines stay visible without being called connected; labels wrap within the strip.",
      props: {
        ...base,
        snapshot: {
          sessions: [],
          peers: ["build-box", "lane-vm"],
          peerKinds: { "build-box": "ssh", "lane-vm": "ssh" },
          peerStatus: {
            "build-box": { state: "connecting", connected: false },
            "lane-vm": { state: "unreachable", connected: false },
          },
        },
      },
    },
  },
});
