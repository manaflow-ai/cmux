import { useEffect } from "react";
import { componentEntry } from "../../gallery/format";
import { OpenAppCard } from "./OpenAppCard";
import { seedCloudPreviewPorts } from "./cloudPreviewPorts";

function OpenAppCardGallery() {
  useEffect(() => {
    seedCloudPreviewPorts([{ port: 3000, process: "vite" }]);
  }, []);
  return (
    <div className="acpmux-stage" style={{ minHeight: 120, paddingTop: 24 }}>
      <OpenAppCard />
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.cloud-open-app-card",
  title: "Cloud Open app card",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/OpenAppCard.tsx#OpenAppCard"],
  styles: () => import("./styles.css"),
  load: async () => OpenAppCardGallery,
  widths: { narrow: 400, normal: 620 },
  height: 180,
  variants: {
    vite: {
      note: "A newly discovered Cloud dev server appears inline with its port and process.",
      props: {},
    },
  },
});
