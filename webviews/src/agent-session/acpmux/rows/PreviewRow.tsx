// The `preview` row: a turn's local web page.
import { memo } from "react";
import { callNative } from "../callNative";
import { PreviewCard } from "../conversation/PreviewCard";
import type { RowProps } from "./rowProps";

/// Asks the host for a browser tab on a turn's local web page; a host without one (the quick
/// panel) refuses, and the card's address still opens outside the pane.
const openPreview = (url: string) => void callNative("browser.open", { url }).catch(() => undefined);
/// A turn's local web page, live (conversation/PreviewCard.tsx).
export const PreviewRow = memo(
  function PreviewRow({ row }: RowProps) {
    return row.text ? <PreviewCard url={row.text} onOpen={openPreview} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.text === b.row.text,
);
