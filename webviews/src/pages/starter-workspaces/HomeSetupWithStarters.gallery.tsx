// l10n-allow-file: gallery fixture.
// The real Set Up cmux page (SetupCardPage) on Home as the app mounts it, now with the starters under it.
import { componentEntry } from "../../gallery/format";
import { SetupCardPage } from "../setup-card/SetupCardPage";
import type { SetupCardStore } from "../setup-card/store";
import type { SetupState } from "../setup-card/setupModel";

const state: SetupState = {
  agents: [
    { id: "claude", name: "Claude Code", state: "signedIn" },
    { id: "codex", name: "Codex", state: "missing" },
  ],
  account: { signedIn: true, email: "you@example.com" },
  cli: "missing",
  classic: null,
};
const store = {
  subscribe: () => () => {},
  getSnapshot: () => state,
  send: () => {},
} as unknown as SetupCardStore;

function Stage() {
  return (
    <div style={{ padding: 16, maxWidth: 600 }}>
      <SetupCardPage store={store} />
    </div>
  );
}

export default componentEntry<Record<string, never>>({
  id: "home.setup-with-starters",
  title: "Set Up cmux with starters",
  area: "Home and Chief",
  height: 1000,
  widths: { narrow: 390, normal: 640, wide: 900 },
  covers: ["pages/setup-card/SetupCardPage.tsx"],
  load: async () => Stage,
  variants: { home: { note: "The page the app hosts on Home: setup rows, then starter demos.", props: {} } },
});
