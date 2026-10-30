// l10n-allow-file: gallery fixtures, not shipped UI.
// The Artifacts page (cmux-page://cmux.artifacts/): the same ArtifactsPage main.tsx mounts, over the
// mock `cmux.artifacts.*` provider instead of the host bridge.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import { pageError, type PageClient } from "../shared/pageClient";
import table from "./generated/strings.json";
import { ArtifactsPage } from "./ArtifactsPage";
import { MockArtifactsProvider, type MockArtifactsKind } from "./mockProvider";
import { ArtifactsStore } from "./store";

type Props = { kind?: MockArtifactsKind; open?: string; signedOut?: boolean };

/** A host that answers every read as signed out, in the app's words. */
const signedOutHost: PageClient = {
  call: async () => {
    throw pageError("cmux.artifacts.signed_out", "Sign in to cmux to see your artifacts.", true);
  },
  subscribe: async () => () => {},
  handle: () => () => {},
};

function ArtifactsGallery({ kind = "synced", open, signedOut = false }: Props) {
  const [store] = useState(() => new ArtifactsStore(signedOut ? signedOutHost : new MockArtifactsProvider(kind)));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start().then(() => (open ? store.select(open) : undefined));
  }, [store, open]);
  return <ArtifactsPage store={store} strings={strings} />;
}

export default componentEntry<Props>({
  id: "pages.artifacts",
  title: "Artifacts",
  area: "Pages",
  experimental: true,
  height: 640,
  widths: { narrow: 560, normal: 900, wide: 1200 },
  covers: ["page:cmux.artifacts", "pages/artifacts/ArtifactsPage.tsx"],
  load: async () => ArtifactsGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    html: {
      note: "An HTML artifact drawn in a scriptless sandboxed frame, with its one revision.",
      props: { open: "artifacts/release-dashboard/index.html" },
    },
    memory: {
      note: "A synced memory note with two revisions: the newest one's change against its parent.",
      props: { open: "memory/claude/artifacts-pane.md" },
    },
    empty: { note: "Nothing saved yet.", props: { kind: "empty" } },
    "signed-out": { note: "Signed out: the app's own words.", props: { signedOut: true } },
  },
});
