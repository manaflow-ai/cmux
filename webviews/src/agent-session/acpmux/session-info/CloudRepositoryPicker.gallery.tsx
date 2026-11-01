// l10n-allow-file: gallery-only fake cloud.repo contract.
import { useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SessionInfoPanel } from "./SessionInfo";
import { CloudRepositoryPicker, type CloudRepo } from "./CloudRepositoryPicker";

type Props = { repos: CloudRepo[] };

function GalleryPicker({ repos }: Props) {
  const anchor = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(true);
  const [attached, setAttached] = useState<string[]>([]);
  const request = async <T,>(method: string): Promise<T> => {
    if (method === "cloud.repo.list") return { repos } as T;
    return { state: "done", repo: repos[0]?.fullName ?? "acme/demo", folder: "~/chats/demo/demo", head: "abc123" } as T;
  };
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <SessionInfoPanel width={320} placement="overlay">
        <ul className="acpmux-session-info-list">
          <li>
            <button ref={anchor} type="button" className="acpmux-session-info-row acpmux-session-info-row--button" onClick={() => setOpen(true)}>
              <span className="acpmux-session-info-row__name">Add repository…</span>
            </button>
          </li>
          {attached.map((repo) => <li key={repo} className="acpmux-session-info-row"><span className="acpmux-session-info-row__name">{repo}</span></li>)}
        </ul>
        <CloudRepositoryPicker
          session="cloud-demo"
          anchor={anchor}
          open={open}
          onOpenChange={setOpen}
          request={request}
          onAttached={(repo) => setAttached((current) => [...current, repo.repo])}
        />
      </SessionInfoPanel>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.cloud-repository-picker",
  title: "Cloud Add repository picker",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 360, normal: 600, wide: 720 },
  covers: ["agent-session/acpmux/session-info/CloudRepositoryPicker.tsx#CloudRepositoryPicker"],
  styles: () => Promise.all([import("../styles.css"), import("./sessionInfo.css")]),
  load: async () => GalleryPicker,
  variants: {
    mixed: {
      note: "Local, recent, and GitHub installation results show quiet source labels; Return attaches the highlighted repo.",
      props: {
        repos: [
          { fullName: "acme/cmux", source: "local" },
          { fullName: "acme/cmux-platform", private: true, source: "recent" },
          { fullName: "manaflow-ai/cmux", source: "installation" },
        ],
      },
    },
    empty: { note: "An empty search has a quiet no-results message.", props: { repos: [] } },
  },
});
