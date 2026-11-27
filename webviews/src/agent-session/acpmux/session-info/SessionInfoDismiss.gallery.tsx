// l10n-allow-file: synthetic gallery labels and pull requests, not shipped UI.
import { useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { Dialog } from "../../../ui/Dialog";
import { ChangesSection } from "./ChangesSection";
import { CloudRepositoryPicker } from "./CloudRepositoryPicker";
import { SessionInfoPanel } from "./SessionInfo";

function SessionInfoDismiss({ inDialog = false }: { inDialog?: boolean }) {
  const [open, setOpen] = useState(true);
  const [repositoryOpen, setRepositoryOpen] = useState(false);
  const repositoryAnchor = useRef<HTMLButtonElement>(null);
  const content = (
    <section className="acpmux-shell" style={{ height: "100%", minHeight: 240 }}>
      <button className="ui-button" data-outside-panel type="button" onClick={() => undefined}>
        Outside Session Info
      </button>
      {open && (
        <SessionInfoPanel width={360} placement="overlay" onDismiss={() => setOpen(false)}>
          <div className="acpmux-session-info__body">
            <ChangesSection
              statuses={{}}
              pullRequests={[
                {
                  url: "https://github.com/example/project/pull/42",
                  repo: "example/project",
                  number: 42,
                  title: "Keep nested menu dismissal in its own layer",
                  opened: true,
                  state: "open",
                },
              ]}
            />
            <button
              ref={repositoryAnchor}
              className="ui-button"
              data-repository-trigger
              type="button"
              aria-haspopup="dialog"
              aria-expanded={repositoryOpen}
              onClick={() => setRepositoryOpen(!repositoryOpen)}
            >
              Add repository
            </button>
            <CloudRepositoryPicker
              session="gallery"
              anchor={repositoryAnchor}
              open={repositoryOpen}
              onOpenChange={setRepositoryOpen}
              onAttached={() => undefined}
              request={async <T,>() => ({ repos: [{ fullName: "example/project", source: "installation" }] }) as T}
            />
            <button className="ui-button" data-inside-panel type="button" onClick={() => undefined}>
              Inside Session Info
            </button>
          </div>
        </SessionInfoPanel>
      )}
    </section>
  );
  return inDialog ? (
    <Dialog open onOpenChange={() => undefined} label="Session Info dialog">
      {content}
    </Dialog>
  ) : (
    content
  );
}

export default componentEntry<{ inDialog?: boolean }>({
  id: "agent-pane.session-info-dismiss",
  title: "Session Info nested menu dismissal",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 640, normal: 900 },
  covers: ["agent-session/acpmux/session-info/SessionInfo.tsx#SessionInfoPanel"],
  load: async () => SessionInfoDismiss,
  variants: {
    panel: { props: {} },
    "dialog-panel": {
      note: "An ancestor dialog does not count as a child popup or prevent Session Info from dismissing.",
      props: { inDialog: true },
    },
    "repository-picker": {
      note: "The child repository picker is a dialog popup, and consumes its own outside press.",
      props: {},
      play: async (ctx) => {
        await ctx.click({ selector: "[data-repository-trigger]" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-repository-picker"));
      },
    },
    "menu-open": {
      note: "The PR menu is portalled outside Session Info. Dismissing it leaves Session Info open.",
      props: {},
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-session-info-pr__more" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
      },
    },
  },
});
