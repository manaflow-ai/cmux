// l10n-allow-file: gallery fixtures, not shipped UI (the host localizes every card).
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { ImportCards, type ImportCardData, type ImportCardList } from "./ImportCards";

type Props = { list: ImportCardList };

const notNow = { action: "dismiss", title: "Not Now" };
const more = { action: "more", title: "More Options…" };

const chrome: ImportCardData = {
  id: "browser.chrome",
  kind: "browser",
  title: "Chrome",
  facts: "3 profiles · history, bookmarks and cookies",
  benefit: "Sites you're signed into in Chrome stay signed in here, and your history fills the address bar.",
  state: "ready",
  primary: { action: "start", title: "Import" },
  secondary: [more, notNow],
  dismissed: false,
};

const claude: ImportCardData = {
  id: "agents.claudeCode",
  kind: "claudeCode",
  title: "Claude Code",
  facts: "412 sessions",
  benefit: "Your Claude Code history becomes searchable chats. Open one to pick up where you left off.",
  state: "ready",
  primary: { action: "start", title: "Show Chats" },
  secondary: [notNow],
  dismissed: false,
};

const codex: ImportCardData = {
  id: "agents.codex",
  kind: "codex",
  title: "Codex",
  facts: "88 threads",
  benefit: "Your Codex threads become searchable chats. Open one to pick up where you left off.",
  state: "ready",
  primary: { action: "start", title: "Show Chats" },
  secondary: [notNow],
  dismissed: false,
};

const request: ImportCardData = {
  id: "request.cookies.chrome.github.com",
  kind: "browser",
  title: "Import Chrome cookies for github.com",
  facts: "Asked by Chief",
  reason: "github.com asks me to sign in, and Chrome is signed in there.",
  benefit: "You stay signed in to github.com in cmux's browser. Only that site's cookies come over.",
  state: "ready",
  primary: { action: "start", title: "Import" },
  secondary: [notNow],
  dismissed: false,
};

const running: ImportCardData = {
  ...chrome,
  state: "running",
  progress: 0.42,
  status: "Importing…",
  secondary: [],
};
delete running.primary;

const paused: ImportCardData = {
  ...chrome,
  id: "browser.arc",
  title: "Arc",
  facts: "1 profile · history and bookmarks",
  benefit: "Your Arc history and bookmarks fill cmux's address bar.",
  state: "paused",
  progress: 0.5,
  status: "Paused when cmux quit. Resume to finish.",
  primary: { action: "resume", title: "Resume" },
  secondary: [{ action: "hide", title: "Not Now" }],
};

const done: ImportCardData = {
  ...chrome,
  state: "done",
  status: "Done: 4,812 pages, 312 bookmarks and 1,904 cookies",
  secondary: [{ action: "hide", title: "Done" }],
};
delete done.primary;

const safari: ImportCardData = {
  id: "browser.safari",
  kind: "browser",
  title: "Safari",
  facts: "Needs Full Disk Access",
  benefit: "Turn on Full Disk Access for cmux in System Settings to bring Safari's history and bookmarks.",
  state: "info",
  primary: { action: "open", title: "Open System Settings" },
  secondary: [notNow],
  dismissed: false,
};

const ghostty: ImportCardData = {
  id: "terminal.ghostty",
  kind: "ghostty",
  title: "Ghostty",
  facts: "Already in use",
  benefit: "cmux terminals already use your Ghostty config: fonts, theme and keys.",
  state: "info",
  primary: { action: "open", title: "Open Config" },
  secondary: [],
  dismissed: false,
};

const iterm: ImportCardData = {
  id: "terminal.iterm2",
  kind: "iterm2",
  title: "iTerm2",
  facts: "2 profiles",
  benefit: "Your iTerm2 colors become a cmux terminal theme you can pick in Appearance.",
  state: "ready",
  primary: { action: "start", title: "Import Colors" },
  secondary: [{ action: "restore", title: "Show Again" }],
  dismissed: true,
};

const failed: ImportCardData = {
  ...codex,
  id: "browser.firefox",
  kind: "browser",
  title: "Firefox",
  facts: "1 profile · history, bookmarks and cookies",
  benefit: "Sites you're signed into in Firefox stay signed in here, and your history fills the address bar.",
  state: "failed",
  status: "Stopped: access wasn't allowed.",
  primary: { action: "retry", title: "Try Again" },
  secondary: [{ action: "hide", title: "Not Now" }],
};

const settings = (cards: ImportCardData[]): ImportCardList => ({
  title: "Found on This Mac",
  cards,
  empty: "Nothing to bring over right now. cmux looks again when you come back to it.",
});

/// The cards with the host stood in: Not Now takes a card away, as the host's next push would.
function GalleryImportCards({ list }: Props) {
  const [cards, setCards] = useState(list.cards);
  const [pressed, setPressed] = useState("");
  return (
    <div className="import-cards-gallery" data-import-cards-fixture style={{ padding: 20, maxWidth: 560 }}>
      <ImportCards
        list={{ ...list, cards }}
        onAction={(id, action) => {
          setPressed(`${id} ${action}`);
          if (action === "dismiss" || action === "hide") setCards((current) => current.filter((c) => c.id !== id));
        }}
      />
      <p data-testid="import-cards-receipt" hidden>
        {pressed}
      </p>
    </div>
  );
}

const dismissOne: Play = async (ctx) => {
  await ctx.click({ selector: '[data-import-card="agents.codex"] [data-action="dismiss"]' });
  await ctx.waitFor(() => !ctx.document.querySelector('[data-import-card="agents.codex"]'));
};

export default componentEntry<Props>({
  id: "ui.import-cards",
  title: "Import suggestion cards",
  area: "UI primitives",
  height: 300,
  widths: { narrow: 380, normal: 760, wide: 980 },
  anchors: [{ selector: '[data-import-card="browser.chrome"]' }],
  covers: ["ui/ImportCards.tsx#ImportCards"],
  load: async () => GalleryImportCards,
  styles: () => import("./ui.css"),
  variants: {
    settings: {
      note: "Settings › Import lists everything found: done, failed, info cards and a dismissed one with Show Again.",
      props: { list: settings([done, failed, safari, ghostty, iterm]) },
      height: 820,
    },
    "settings-ready": {
      note: "Settings › Import: what one click imports, each with what was found and what you get.",
      props: { list: settings([chrome, claude, codex]) },
      height: 560,
    },
    "settings-request": {
      note: "Chief raised a card for a sign-in wall: it leads, with Chief's reason in its words.",
      props: { list: settings([request, chrome, claude]) },
      height: 600,
    },
    "settings-running": {
      note: "An import runs in the background with its progress; a paused one offers Resume.",
      props: { list: settings([running, paused, claude]) },
      height: 560,
    },
    "settings-dismiss": {
      note: "Play: Not Now takes the Codex card away; it comes back only when something new appears.",
      props: { list: settings([chrome, claude, codex]) },
      height: 560,
      play: dismissOne,
    },
    "settings-empty": {
      note: "Settings › Import with nothing found.",
      props: { list: settings([]) },
      height: 120,
    },
  },
});
