// l10n-allow-file: gallery fixtures (sample pages and extensions), not shipped UI.
import type { BrowserToolbarProps } from "./BrowserToolbar";
import type { SuggestionRow } from "./SuggestionDropdown";
import { resolveChip, type ExtensionAction, type OmnibarState, type ToolbarButton } from "./toolbarModel";

const favicon = (fill: string) =>
  `data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="4" fill="${fill}"/></svg>`,
  )}`;

export const pinnedExtensions: ExtensionAction[] = [
  { id: "notes", name: "Quick Notes", iconUrl: favicon("#d9822b") },
  {
    id: "blocker",
    name: "Content Blocker",
    iconUrl: favicon("#7a4fd1"),
    badge: { text: "12", color: "#5d6b7a" },
  },
  { id: "reader", name: "Reader" },
];

const secureText = "docs.example.com/guide/getting-started";

export const secureOmnibar: OmnibarState = {
  text: secureText,
  host: [0, "docs.example.com".length],
  chip: resolveChip({ kind: "web", connection: "secure", displayName: "docs.example.com" }),
  bookmark: "off",
};

export const defaultButtons: ToolbarButton[] = [{ id: "downloads", inProgress: true, progress: 0.4 }];

export const everyButton: ToolbarButton[] = [
  { id: "media" },
  { id: "zoom", percent: 125 },
  { id: "favorites" },
  { id: "downloads" },
  { id: "designMode", enabled: true },
  { id: "profile", name: "Work" },
  { id: "theme", scheme: "dark" },
  { id: "devTools", available: true, open: true },
];

export function toolbarProps(
  overrides: Partial<Omit<BrowserToolbarProps, "onCommand">> = {},
): Omit<BrowserToolbarProps, "onCommand"> {
  return {
    navigation: { canGoBack: true, canGoForward: false, loading: false },
    omnibar: secureOmnibar,
    extensions: { shows: true, pinned: pinnedExtensions },
    buttons: defaultButtons,
    ...overrides,
  };
}

export const typedSuggestions: SuggestionRow[] = [
  { kind: "navigate", title: "docs.example.com", detail: "" },
  { kind: "search", title: "docs example guide", detail: "Google Search" },
  {
    kind: "history",
    title: "Getting started · Example Docs",
    detail: "docs.example.com/guide/getting-started",
    faviconUrl: favicon("#2b8a5e"),
  },
  {
    kind: "bookmark",
    title: "Example Docs API reference",
    detail: "docs.example.com/api",
    faviconUrl: favicon("#2b8a5e"),
  },
  {
    kind: "switchToTab",
    title: "Example Docs changelog",
    detail: "Switch to Tab",
    faviconUrl: favicon("#2b8a5e"),
  },
  { kind: "search", title: "docs example guide pdf", detail: "Google Search" },
];
