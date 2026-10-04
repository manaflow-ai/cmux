// Boots the icon picker page: one page per app, loaded once and kept warm, shown in a native
// popover for each pick (IconPickerPopover.swift). Each open arrives as a `cmux.iconPicker.session`
// event; the page resets its store and focuses the search field. `?mock` runs it in a browser with
// in-memory stand-ins (dev loop and the bench). main.tsx boots it; tests mount it directly.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { createStrings, type Strings } from "../shared/i18n";
import type { PageClient } from "../shared/pageClient";
import { decodeEmojiTable, warmSearch, type RawEmojiTable } from "../../icon-picker/emojiData";
import rawEmoji from "../../icon-picker/generated/emoji-data.json";
import { encodeIcon, type IconValue } from "../../icon-picker/iconValue";
import { IconPicker } from "../../icon-picker/IconPicker";
import { PickerStore } from "../../icon-picker/store";
import table from "./generated/strings.json";
import { hostAssets, hostPrefs, IconPickerOps, type PickerSession } from "./host";

export interface MountedPicker {
  readonly store: PickerStore;
  /** Starts a session (the host's stream calls this; the bench calls it directly). */
  open(session: PickerSession): void;
  /** Unmounts the picker and ends its session stream (the page shell's reset). */
  unmount(): void;
}

export function mountIconPicker(
  root: HTMLElement,
  client: PageClient | null,
  strings: Strings = createStrings(table),
  makeRoot: typeof createRoot = createRoot,
  /** A session to show from the first render (the page shell's claim): one render, no remount. */
  initial?: PickerSession,
): MountedPicker {
  const emoji = decodeEmojiTable(rawEmoji as RawEmojiTable);
  const store = new PickerStore({
    emoji,
    prefs: client ? hostPrefs(client) : undefined,
    language: strings.language,
    titles: (id) => strings.t(`iconPicker.section.${id}`),
  });
  let session: PickerSession = { id: "" };
  // The React key: a new session remounts the picker (fresh scroll and fields), except the first
  // session of a picker that never showed one (a page shell spare prepared ahead of its claim).
  let renderKey = "";
  const finish = (result: { value?: string; clear?: true; cancel?: true }) =>
    void client?.call(IconPickerOps.finish, { session: session.id, ...result }).catch(() => undefined);
  const reactRoot = makeRoot(root);
  const render = () =>
    reactRoot.render(
      <IconPicker
        key={renderKey}
        store={store}
        strings={strings}
        onPick={(value: IconValue) => finish({ value: encodeIcon(value) })}
        onCancel={() => finish({ cancel: true })}
        onClear={session.canClear ? () => finish({ clear: true }) : undefined}
        assets={client && session.assets ? hostAssets(client) : undefined}
        symbolImageURL={(name) => `./__symbol/${encodeURIComponent(name)}.png`}
      />,
    );
  const open = (next: PickerSession) => {
    if (next.symbols) store.configure(next.symbols, next.maxEmojiVersion);
    if (session.id) renderKey = next.id;
    session = next;
    store.reset(next.tab ?? "emoji");
    // Synchronous so the host can show the popover right after this event without a stale frame.
    flushSync(render);
    root.querySelector<HTMLInputElement>(".icon-picker-search")?.focus();
  };
  document.documentElement.lang = strings.language;
  document.title = strings.t("iconPicker.title");
  if (initial?.id) {
    if (initial.symbols) store.configure(initial.symbols, initial.maxEmojiVersion);
    session = initial;
    store.reset(initial.tab ?? "emoji");
  }
  flushSync(render);
  if (initial?.id) root.querySelector<HTMLInputElement>(".icon-picker-search")?.focus();
  // The search text is built after the first frame, so it is ready before the first keystroke
  // without slowing the page's first paint.
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => setTimeout(() => warmSearch(emoji), 0));
  let unsubscribe: (() => void) | undefined;
  let mounted = true;
  if (client)
    void client
      .subscribe<PickerSession>(IconPickerOps.session, (data) => open(data))
      .then((stop) => (mounted ? (unsubscribe = stop) : stop()))
      .catch(() => undefined);
  const unmount = () => {
    mounted = false;
    unsubscribe?.();
    reactRoot.unmount();
  };
  return { store, open, unmount };
}
