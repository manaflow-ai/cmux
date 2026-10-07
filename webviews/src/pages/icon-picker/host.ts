// The icon picker page's ops with its host (the native popover, IconPickerPopover.swift). The page
// owns no data: the host opens a session per picker use and applies the result through the same
// catalog action the palette and CLI run (for example `workspace.setIcon`).
import type { PageClient } from "../shared/pageClient";
import type { IconAssetSink } from "../../icon-picker/AssetTab";
import { decodeIcon, type IconValue } from "../../icon-picker/iconValue";
import { decodePrefs, type PickerPrefs, type PickerPrefsStore } from "../../icon-picker/recents";
import type { SymbolCatalog, SymbolCategory } from "../../icon-picker/symbols";

export const IconPickerOps = {
  /** Stream: one event per picker open in the reused page. */
  session: "cmux.iconPicker.session",
  /** {value: wire icon string} or {clear: true} or {cancel: true}. */
  finish: "cmux.iconPicker.finish",
  prefsLoad: "cmux.iconPicker.prefs.load",
  prefsSave: "cmux.iconPicker.prefs.save",
  /** {kind, base64} -> {icon: wire string}; the host stores the asset with the object's owner. */
  assetPut: "cmux.iconPicker.asset.put",
  /** {kind, url} -> {icon}; the host downloads (https only) and stores. */
  assetFromURL: "cmux.iconPicker.asset.fromURL",
} as const;

export interface PickerSession {
  /** Session id; finish echoes it so a late reply never applies to a newer session. */
  readonly id: string;
  /** The current icon (wire string), if any. */
  readonly value?: string | null;
  readonly tab?: "emoji" | "symbol" | "image" | "svg";
  readonly canClear?: boolean;
  readonly assets?: boolean;
  /** The SF Symbol catalog, first session of a page only: names in the system's order. */
  readonly symbols?: readonly string[];
  /** Aligned with `symbols`: space-separated search keywords. */
  readonly symbolKeywords?: readonly string[];
  /** The system categories with their members (indices into `symbols`). */
  readonly symbolCategories?: readonly SymbolCategory[];
  readonly maxEmojiVersion?: number;
  /** Changes when the host's symbol drawing changes (light or dark); every session. */
  readonly symbolStyle?: string;
}

/** The session's symbol catalog, or null when the session carries none (a later session). */
export function sessionCatalog(session: PickerSession): SymbolCatalog | null {
  if (!session.symbols) return null;
  return { names: session.symbols, keywords: session.symbolKeywords, categories: session.symbolCategories };
}

export function hostPrefs(client: PageClient): PickerPrefsStore {
  return {
    load: async () => decodePrefs(await client.call(IconPickerOps.prefsLoad, {}).catch(() => null)),
    save: (prefs: PickerPrefs) => void client.call(IconPickerOps.prefsSave, { prefs }).catch(() => undefined),
  };
}

async function base64(data: Blob): Promise<string> {
  const bytes = new Uint8Array(await data.arrayBuffer());
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
}

function iconReply(reply: unknown): IconValue {
  const value = decodeIcon((reply as { icon?: string } | null)?.icon);
  if (!value) throw new Error("bad icon reply");
  return value;
}

export function hostAssets(client: PageClient): IconAssetSink {
  return {
    put: async (kind, data) =>
      iconReply(await client.call(IconPickerOps.assetPut, { kind, base64: await base64(data) })),
    fromURL: async (kind, url) => iconReply(await client.call(IconPickerOps.assetFromURL, { kind, url })),
  };
}
