// l10n-allow-file: gallery fixtures, not shipped UI.
// The Mobile Pairing page (cmux-page://cmux.mobile-pairing/) before its status answers: the real
// MobilePairingStore and page over a host whose status read never answers (or answers late), on
// the store's own 10 s deadline (ui-state-fixes M9 captures).
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MobilePairingPage } from "./MobilePairingPage";
import { MockMobilePairingProvider } from "./mockProvider";
import { MOBILE_PAIRING_DEADLINE_MS, MobilePairingStore } from "./store";
import { MobilePairingOps } from "./types";

type Host = "silent" | "late";
type Props = { host?: Host };

/// A host whose status read never answers (`silent`), or answers the mock's signed-out status
/// `LATE_MS` after it was asked, past the page's deadline (`late`).
const LATE_MS = MOBILE_PAIRING_DEADLINE_MS + 3_000;

class GalleryPairingHost implements PageClient {
  private readonly mock = new MockMobilePairingProvider();
  constructor(private readonly host: Host) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    if (op !== MobilePairingOps.status) return this.mock.call<R>(op, params);
    if (this.host === "silent") return new Promise<R>(() => undefined);
    return new Promise<R>((resolve) => setTimeout(() => void this.mock.call<R>(op, params).then(resolve), LATE_MS));
  }

  async subscribe<E>(stream: string): Promise<() => void> {
    if (stream !== MobilePairingOps.changes) throw pageError("cmux.op.unknown", stream);
    return () => undefined;
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }
}

function MobilePairingGallery({ host = "silent" }: Props) {
  const [store] = useState(() => new MobilePairingStore(new GalleryPairingHost(host)));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  return <MobilePairingPage store={store} strings={strings} />;
}

const text = (ctx: Parameters<Play>[0]) => ctx.document.body.textContent ?? "";
const failed: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".pairing-panel .pairing-button"), {
    capMs: MOBILE_PAIRING_DEADLINE_MS + 4_000,
  });
};

export default componentEntry<Props>({
  id: "pages.mobile-pairing",
  title: "Mobile Pairing",
  area: "Pages",
  height: 420,
  widths: { narrow: 380, normal: 640, wide: 820 },
  covers: ["page:cmux.mobile-pairing", "pages/mobile-pairing/MobilePairingPage.tsx#MobilePairingPage"],
  load: async () => MobilePairingGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    loading: {
      note: "The status is asked and the host has not answered yet: Loading…",
      props: {},
      play: async (ctx) => {
        await ctx.waitFor(() => text(ctx).includes("Loading"));
      },
    },
    "failed-after-deadline": {
      note: "The host never answers: past the page's 10 s deadline it says the status did not load, with Retry.",
      props: {},
      play: failed,
    },
    "retry-loading-again": {
      note: "Retry under the failure: the page shows Loading… again, under a fresh deadline.",
      props: {},
      play: async (ctx) => {
        await failed(ctx);
        await ctx.click({ selector: ".pairing-panel .pairing-button" });
        await ctx.waitFor(() => !ctx.document.querySelector(".pairing-panel") && text(ctx).includes("Loading"));
      },
    },
    "late-status": {
      note: "The status answers 13 s in, after the failure showed: it replaces the failure.",
      props: { host: "late" },
      play: async (ctx) => {
        await failed(ctx);
        await ctx.waitFor(() => !ctx.document.querySelector(".pairing-panel") && !text(ctx).includes("Loading"), {
          capMs: 8_000,
        });
      },
    },
  },
});
