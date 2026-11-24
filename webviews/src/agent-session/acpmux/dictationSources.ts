// What the composer's mic dictates with (`agentPane.dictationSource`, composerSettings.ts): cmux's
// own dictation (the default), macOS Dictation, or a dictation app the person already uses, whose
// shortcut the host sends when the mic is pressed (`dictation.handoff`; Swift
// AgentPaneDictationHandoff). The page never names the keys: the host reads the source and its
// shortcut from the settings, so page script cannot type into another app. The mic's right-click
// lists cmux, macOS Dictation and each app this Mac has (`dictation.sources`), asked when the mic
// first shows and again each time its menu opens. Leo, 2026-11-07: "you can optionally have it be
// like, oh, you use Claude's thing, or ChatGPT's thing, or like it detects Claude's thing or
// ChatGPT's thing if you have that app open ... Or, like, maybe you can map the button to that thing,
// perhaps?" (design/composer-dictation.md).
import { useEffect, useSyncExternalStore } from "react";
import { callHost } from "./composer/attachmentSources";
import type { DictationSource } from "./composerSettings";
import type { StringKey, Translate } from "./i18n";

/// A dictation app this Mac has, as the host lists it.
export type InstalledDictationApp = { id: DictationSource; bundleId: string };

/// The apps' names: brand names, the same in every language. macOS Dictation's is a string.
const APP_NAMES: Partial<Record<DictationSource, string>> = {
  chatgpt: "ChatGPT",
  claude: "Claude",
  gemini: "Gemini",
  wisprFlow: "Wispr Flow",
  superwhisper: "Superwhisper",
};

/// The source's name for menus and labels.
export function dictationSourceName(source: DictationSource, t: Translate): string {
  if (source === "cmux") return "cmux";
  if (source === "macos") return t("dictation.source.macos");
  return APP_NAMES[source] ?? source;
}

/// Sources that are apps (their icon goes on the mic); cmux and macOS Dictation keep the mic.
export const isAppSource = (source: DictationSource) => source !== "cmux" && source !== "macos";

let installed: readonly InstalledDictationApp[] = [];
let asking = false;
const listeners = new Set<() => void>();

const isSource = (value: unknown): value is DictationSource => typeof value === "string" && value in APP_NAMES;

/// Asks the host which dictation apps this Mac has (at most one ask at a time). An older host, or a
/// page with none, lists none: the menu then offers cmux and macOS Dictation only.
export function refreshDictationApps(): void {
  if (asking) return;
  asking = true;
  void callHost("dictation.sources", {})
    .then((answer) => {
      const list = (answer as { sources?: unknown } | null | undefined)?.sources;
      return Array.isArray(list)
        ? list.flatMap((item: unknown) => {
            const app = item as Partial<InstalledDictationApp> | null;
            return app && isSource(app.id) && typeof app.bundleId === "string"
              ? [{ id: app.id, bundleId: app.bundleId }]
              : [];
          })
        : [];
    })
    .catch(() => [])
    .then((next) => {
      asking = false;
      const same =
        next.length === installed.length &&
        next.every((app, index) => {
          const was = installed[index];
          return was && was.id === app.id && was.bundleId === app.bundleId;
        });
      if (same) return;
      installed = next;
      for (const listener of listeners) listener();
    });
}

/// Test and gallery seam: the apps as a host would list them.
export function setDictationApps(apps: readonly InstalledDictationApp[]): void {
  installed = apps;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
const read = () => installed;

/// The dictation apps this Mac has; the first use asks the host.
export function useDictationApps(): readonly InstalledDictationApp[] {
  useEffect(() => {
    if (!installed.length) refreshDictationApps();
  }, []);
  return useSyncExternalStore(subscribe, read, read);
}

/// The notice for a hand-off the host refused (its error code), naming the source.
export function handoffFailure(code: string | undefined, source: DictationSource, t: Translate): string {
  const name = dictationSourceName(source, t);
  const key: StringKey =
    code === "dictation.app_not_installed"
      ? "dictation.handoff.notInstalled"
      : code === "dictation.accessibility"
        ? "dictation.handoff.accessibility"
        : code === "dictation.bad_shortcut"
          ? "dictation.handoff.badShortcut"
          : "dictation.handoff.failed";
  return t(key, { name });
}
