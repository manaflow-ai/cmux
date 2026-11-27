// l10n-allow-file: a browser fixture's repository names, not shipped UI.
// The cloud Add repository picker (session-info/CloudRepositoryPicker.tsx), open, with N
// repositories from a stub of the host's `cloud.repo.list` (it filters by the query as the host
// does). The picker has no live update of one repository, so there is no changeOne step.
import { useRef } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import "../../../src/agent-session/acpmux/styles.css";
import "../../../src/agent-session/acpmux/session-info/sessionInfo.css";
import {
  CloudRepositoryPicker,
  type CloudRepo,
} from "../../../src/agent-session/acpmux/session-info/CloudRepositoryPicker";
import { caseItems, type VisibleListCase } from "./case";

function CasePicker({ repos }: { repos: CloudRepo[] }) {
  const anchor = useRef<HTMLButtonElement>(null);
  const request = async <T,>(method: string, params?: Record<string, unknown>): Promise<T> => {
    if (method !== "cloud.repo.list") return {} as T;
    const query = typeof params?.query === "string" ? params.query : "";
    return { repos: query ? repos.filter((repo) => repo.fullName.includes(query)) : repos } as T;
  };
  return (
    <div className="acpmux-shell">
      <button ref={anchor} type="button">
        Add repository
      </button>
      <CloudRepositoryPicker
        session="visible-lists"
        anchor={anchor}
        open
        onOpenChange={() => {}}
        onAttached={() => {}}
        request={request}
      />
    </div>
  );
}

const ROW = ".acpmux-cloud-repository-option";

const cloudRepositoryPickerCase: VisibleListCase = {
  async mount(root, n) {
    const repos: CloudRepo[] = caseItems(n).map((item, index) => ({
      fullName: `acme/${item.label}`,
      source: index % 3 === 0 ? "local" : "installation",
    }));
    flushSync(() => createRoot(root).render(<CasePicker repos={repos} />));
    // The list answers after the picker's first read (a timer and the stub's promise).
    for (let tries = 0; !document.querySelector(ROW); tries++) {
      if (tries > 600) throw new Error("the cloud repository picker drew no repositories");
      await new Promise((done) => requestAnimationFrame(done));
    }
    const list = () => document.querySelector<HTMLElement>(".acpmux-cloud-repository-list")!;
    return {
      rowSelector: ROW,
      rowComponents: ["CloudRepositoryOption"],
      scroller: list,
      list,
      filter: () => document.querySelector<HTMLElement>(".acpmux-cloud-repository-search")!,
    };
  },
};
export default cloudRepositoryPickerCase;
