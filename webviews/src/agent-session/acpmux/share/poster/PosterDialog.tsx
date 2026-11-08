// Share poster… (the chat's ••• menu, or ⌥⌘S): the chat's last finished turn as a shareable image
// (Poster.tsx), previewed before anything leaves the Mac. Copy Image puts the PNG on the clipboard,
// Save… writes it through the host's save panel (the host's `image.copy` and `image.save`, which
// the image menu uses too), and Include share link, off by default, prints the chat's viewer link
// on the poster: checking it makes the same link Share…'s Copy link makes (share/shareState.ts).
//
// The poster is built once per open from the turn's rows (posterModel.ts) and drawn to a PNG once
// per change of what it shows, so the buttons act at once on the click the host asks for. No timer
// and no observer.
import { useEffect, useId, useMemo, useRef, useState, type Ref } from "react";
import { Button } from "../../../../ui/Button";
import { Dialog } from "../../../../ui/Dialog";
import { Switch } from "../../../../ui/Switch";
import { translate, useT, type Translate } from "../../i18n";
import type { AcpmuxRow } from "../../model";
import { hasNativeHost, postNative } from "../../native";
import { shareClient, type ShareCall } from "../shareState";
import { Poster, type PosterDesign, type PosterLabels, type PosterTheme } from "./Poster";
import { pngBlob, posterPng } from "./posterImage";
import { buildPoster, type PosterData } from "./posterModel";
import "./poster.css";

export const posterLabels = (t: Translate): PosterLabels => ({
  files: (n) => t("poster.files", { n }),
  before: t("poster.before"),
  after: t("poster.after"),
  madeWith: t("poster.madeWith"),
});

export interface PosterDialogBodyProps {
  data: PosterData;
  design?: PosterDesign;
  theme: PosterTheme;
  includeLink: boolean;
  /** The share link is being made, or the PNG drawn: Copy Image and Save… wait. */
  busy: boolean;
  /** What the last step did, or why it did not. */
  status: string | null;
  svgRef?: Ref<SVGSVGElement>;
  onIncludeLink(include: boolean): void;
  onCopy(): void;
  onSave(): void;
  onDone(): void;
}

/** Render only: the host (PosterDialogHost) runs every step; the gallery draws it from fixtures. */
export function PosterDialogBody({
  data,
  design = "glow",
  theme,
  includeLink,
  busy,
  status,
  svgRef,
  onIncludeLink,
  onCopy,
  onSave,
  onDone,
}: PosterDialogBodyProps) {
  const t = useT();
  const labels = useMemo(() => posterLabels(t), [t]);
  const linkLabel = useId();
  return (
    <div className="poster-dialog">
      <h2 className="poster-dialog__title">{t("poster.title")}</h2>
      <div className="poster-dialog__preview">
        <Poster
          data={data}
          design={design}
          theme={theme}
          labels={labels}
          svgRef={svgRef}
          className="poster-dialog__image"
        />
      </div>
      <p className="poster-dialog__note">{t("poster.private")}</p>
      <div className="poster-dialog__link">
        <span className="poster-dialog__link-text" id={linkLabel}>
          <span>{t("poster.includeLink")}</span>
          <span className="poster-dialog__detail">{t("poster.includeLinkDetail")}</span>
        </span>
        <Switch
          aria-labelledby={linkLabel}
          checked={includeLink}
          onCheckedChange={(checked) => onIncludeLink(checked)}
        />
      </div>
      <output className="poster-dialog__status">{status ?? ""}</output>
      <footer className="poster-dialog__footer">
        <Button variant="subtle" onClick={onDone}>
          {t("share.done")}
        </Button>
        <span className="poster-dialog__actions">
          <Button variant="subtle" disabled={busy} onClick={onSave}>
            {t("poster.save")}
          </Button>
          <Button variant="solid" disabled={busy} onClick={onCopy}>
            {t("poster.copy")}
          </Button>
        </span>
      </footer>
    </div>
  );
}

/// The pane's light or dark when the dialog opens: its theme (shared/theme.ts), not the system's.
const paneTheme = (): PosterTheme => (document.documentElement.dataset.theme === "light" ? "light" : "dark");

/// Copies the PNG: the host's `image.copy` in the app, else the page's clipboard.
async function copyPng(png: string, name: string): Promise<void> {
  if (hasNativeHost()) {
    await postNative("image.copy", { src: png, name: `${name}.png` });
    return;
  }
  await navigator.clipboard.write([new ClipboardItem({ "image/png": pngBlob(png) })]);
}

/// Saves the PNG: the host's save panel in the app, else a download.
async function savePng(png: string, name: string): Promise<void> {
  if (hasNativeHost()) {
    await postNative("image.save", { src: png, name });
    return;
  }
  const link = document.createElement("a");
  link.href = png;
  link.download = `${name}.png`;
  link.click();
}

export function PosterDialogHost({
  open,
  onOpenChange,
  sessionId,
  rows,
  chat,
  title,
  call,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  sessionId: string;
  /** The chat's rows; read once when the dialog opens. */
  rows: readonly AcpmuxRow[];
  chat: { cwd?: string; harness?: string; model?: string };
  /** The chat's title: the saved file's name. */
  title: string;
  /** The host's `share.op`; the gallery passes a fixture. */
  call?: ShareCall;
}) {
  const t = useT();
  // The rows as of the last render, which the open below reads once (declared first, so it runs first).
  const latest = useRef({ rows, chat, close: onOpenChange });
  useEffect(() => {
    latest.current = { rows, chat, close: onOpenChange };
  });
  const [poster, setPoster] = useState<{ data: PosterData; theme: PosterTheme }>();
  const [link, setLink] = useState<string>();
  const [makingLink, setMakingLink] = useState(false);
  const [png, setPng] = useState<string>();
  const [status, setStatus] = useState<string | null>(null);
  // A callback ref kept in state: the dialog mounts its popup after `open`, and the PNG waits for it.
  const [svg, setSvg] = useState<SVGSVGElement | null>(null);
  const client = useMemo(() => shareClient(sessionId, call), [sessionId, call]);
  // Each switch change and each open starts a new request generation: a link that arrives after
  // the switch went off, or after the dialog reopened, is dropped.
  const linkRequest = useRef(0);
  // Each open builds the poster afresh from the turn that finished last, off by default. No
  // finished turn (the chat changed under the menu): the open ends, so the next one starts again.
  useEffect(() => {
    if (!open) return;
    const data = buildPoster(latest.current.rows, latest.current.chat);
    setPoster(data ? { data, theme: paneTheme() } : undefined);
    linkRequest.current++;
    setLink(undefined);
    setMakingLink(false);
    setStatus(null);
    if (!data) latest.current.close(false);
  }, [open]);
  const data = useMemo(() => (poster && link ? { ...poster.data, link } : poster?.data), [poster, link]);
  // The PNG of what the preview shows, drawn after the preview commits.
  useEffect(() => {
    setPng(undefined);
    if (!open || !data || !svg) return;
    let current = true;
    posterPng(svg).then(
      (next) => current && setPng(next),
      () => current && setStatus(translate("poster.error.image")),
    );
    return () => {
      current = false;
    };
  }, [open, data, svg]);
  const includeLink = (include: boolean) => {
    setStatus(null);
    const request = ++linkRequest.current;
    if (!include) {
      setLink(undefined);
      setMakingLink(false);
      return;
    }
    setMakingLink(true);
    void client
      .state()
      .then((view) => client.viewerLink(view))
      .then(
        (url) => request === linkRequest.current && setLink(url),
        () => request === linkRequest.current && setStatus(translate("poster.error.link")),
      )
      .finally(() => request === linkRequest.current && setMakingLink(false));
  };
  const name = title.trim() || t("poster.title");
  /// `done`: what the status line says after; none for Save…, whose panel the person may cancel.
  const act = (work: (png: string, name: string) => Promise<void>, done: string | null) => {
    if (!png) return;
    setStatus(null);
    work(png, name).then(
      () => setStatus(done),
      () => setStatus(translate("poster.error.image")),
    );
  };
  return (
    <Dialog
      open={open && data !== undefined}
      onOpenChange={onOpenChange}
      label={t("poster.title")}
      className="ui-glass ui-glass-floats poster-dialog-popup"
    >
      {data && poster && (
        <PosterDialogBody
          data={data}
          theme={poster.theme}
          includeLink={link !== undefined || makingLink}
          busy={makingLink || !png}
          status={status}
          svgRef={setSvg}
          onIncludeLink={includeLink}
          onCopy={() => act(copyPng, translate("poster.copied"))}
          onSave={() => act(savePng, null)}
          onDone={() => onOpenChange(false)}
        />
      )}
    </Dialog>
  );
}
