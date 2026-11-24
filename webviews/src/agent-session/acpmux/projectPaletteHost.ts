import { useCallback, useId, useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { hasNativeHost, postNative } from "./native";

export const PROJECT_PALETTE_EVENT = "cmux-project-palette";

const SOURCE_PAGES = ["add", "github", "machines", "folders", "url"] as const;
export type SourcePage = (typeof SOURCE_PAGES)[number];
export type SourceIcon = "github" | "folder" | "link" | "plus";

export type ProjectPalettePage = {
  page: SourcePage;
  title: string;
  placeholder: string;
  scope?: { label: string; icon: SourceIcon };
  query: string;
  rows: { id: string; label: string; icon?: SourceIcon; status?: string; enabled: boolean }[];
};

type Event =
  | { type: "closed" }
  | { type: "back"; page: SourcePage; text: string }
  | { type: "query" | "submit"; page: SourcePage; text: string }
  | { type: "pick"; page: SourcePage; id: string };

type Options = {
  model: ProjectPalettePage;
  onEvent(event: Event): void;
};

export function useProjectPaletteHost(open: boolean, options: Options) {
  const fallbackID = useId();
  const [id] = useState(() => globalThis.crypto?.randomUUID?.() ?? fallbackID);
  const [mode, setMode] = useState<"pending" | "native" | "web">(() => (hasNativeHost() ? "pending" : "web"));
  const latest = useRef(options);
  const lastSent = useRef<{ page: SourcePage; serialized: string } | null>(null);
  const active = useRef(false);
  // The latest options for the host's events, written after each render (never during it) and before the effects
  // below read them.
  useLayoutEffect(() => {
    latest.current = options;
  });
  const serialized = open && mode !== "web" ? JSON.stringify(options.model) : "";

  const close = useCallback(() => {
    active.current = false;
    return postNative("projectPalette.close", { id }).catch(() => undefined);
  }, [id]);

  useLayoutEffect(() => {
    if (!open || !hasNativeHost()) return;
    let live = true;
    active.current = true;
    const receive = (event: globalThis.Event) => {
      const detail = (event as CustomEvent<Event & { session: string }>).detail;
      if (!active.current || detail?.session !== id) return;
      if (detail.type !== "closed" && !SOURCE_PAGES.includes(detail.page)) return;
      if (detail.type === "closed") active.current = false;
      if (detail.type === "back") {
        lastSent.current = { page: detail.page, serialized: "" };
        // The next event in this host batch can already target the parent.
        flushSync(() => latest.current.onEvent(detail));
      } else latest.current.onEvent(detail);
    };
    window.addEventListener(PROJECT_PALETTE_EVENT, receive);
    const model = latest.current.model;
    lastSent.current = { page: model.page, serialized: JSON.stringify(model) };
    void postNative<{ shown?: boolean }>("projectPalette.show", { id, model }).then(
      (reply) => {
        if (!live || !active.current) return;
        active.current = reply?.shown === true;
        setMode(active.current ? "native" : "web");
      },
      () => {
        if (!live || !active.current) return;
        active.current = false;
        setMode("web");
      },
    );
    return () => {
      live = false;
      window.removeEventListener(PROJECT_PALETTE_EVENT, receive);
      if (active.current) void close();
    };
  }, [close, id, open]);

  useLayoutEffect(() => {
    if (!active.current || mode !== "native" || !open || lastSent.current?.serialized === serialized) return;
    const model = latest.current.model;
    const push = lastSent.current?.page !== model.page;
    lastSent.current = { page: model.page, serialized };
    void postNative("projectPalette.update", { id, model, push }).catch(() => undefined);
  }, [id, mode, open, serialized]);

  return { mode, close };
}
