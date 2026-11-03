import { createRoot } from "react-dom/client";
import "../../src/pages/shared/desktop.css";
import { FindPill } from "../../src/ui/FindPill";
import { ImportCards } from "../../src/ui/ImportCards";

const noop = () => undefined;
const canStep = new URLSearchParams(location.search).get("canStep") !== "false";

createRoot(document.getElementById("root")!).render(
  <>
    <style>{`
      :root { --cmux-text: CanvasText; --cmux-accent: LinkText; --cmux-app-danger: MarkText; }
      body { margin: 24px; color: CanvasText; background: Canvas; }
    `}</style>
    <FindPill
      query="needle"
      onQueryChange={noop}
      status={canStep ? "1 of 3" : "No matches"}
      noMatches={!canStep}
      canStep={canStep}
      onNext={noop}
      onPrevious={noop}
      onClose={noop}
      matchCase
      onMatchCaseChange={noop}
      labels={{ placeholder: "Find", previous: "Previous", next: "Next", close: "Close", matchCase: "Match case" }}
      icon={(role) => <span>{role}</span>}
      replace={{
        open: true,
        value: "replacement",
        onChange: noop,
        onReplace: noop,
        onReplaceAll: noop,
        onToggle: noop,
        labels: { field: "Replace", replace: "Replace", replaceAll: "All", toggle: "Toggle Replace" },
      }}
    />
    <ImportCards
      list={{
        title: "Found on This Mac",
        cards: [
          {
            id: "browser.fixture",
            kind: "browser",
            title: "Browser",
            facts: "3 profiles",
            benefit: "Bring your bookmarks into cmux.",
            state: "ready",
            dismissed: false,
            primary: { action: "start", title: "Import" },
            secondary: [{ action: "dismiss", title: "Not Now" }],
          },
        ],
      }}
      onAction={noop}
    />
  </>,
);
