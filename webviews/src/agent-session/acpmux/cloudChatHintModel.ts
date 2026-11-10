import { useCallback, useEffect, useRef, useState } from "react";
import type { TipHost } from "../../ui/featureTips/store";
import { pageIsKey, watchPageKey } from "./pageKey";

/// The one-time Cloud hint over a new chat's composer (CloudChatHint.tsx). Leo, 2026-11-08, on
/// teammates starting a Cloud chat: "how would they know?". It says a chat can run in Cloud, with
/// Use Cloud (the Where menu's own Cloud pick) and an X.
///
/// Its record is the app's, as the feature tips' are (`tips.state`, Swift
/// `AgentPaneFeatureTipRecords`, the app's UserDefaults for the life of the install; never a page's
/// own storage, which ends with the launch). It shows at most once per install (Leo, 2026-11-06, on
/// tips and guides: far too many, far too often): when a new chat could show it, the page asks the
/// app (`claim`), and the app says yes only once, and only when no tip showed in the last 14 days,
/// spending that one budget the feature tips and the sidebar's card share. Once shown, a later new
/// chat, a close or a Cloud pick by any path (the hint, the Where menu, New Cloud Chat in the
/// palette) ends it for good; a no ends it for this page only, so a later page may ask again once
/// the budget is open. An app that keeps no records shows no hint, since a hint that could
/// not stay closed must not show at all; neither does an install whose feature tips are off.
///
/// A New Tab page changes hands (CMD-T BUDGET 3, 2026-11-10): it loads as a spare that nobody sees,
/// Cmd-T gives it to a tab, and a Cmd-W gives it back to the spare pool for the next Cmd-T
/// (NewTabSparePool.recycle). So the page holds no hint of its own past a change of hands:
/// - Only the page the person is at asks (`useCloudChatHintClaim`: the key page, `pageKey.ts`; the
///   feature tips' own rule is the same, `pageFocused`). A spare never asks, so a claim never spends
///   the budget on a hint nobody saw, and the tab that takes the spare asks when it shows.
/// - Each adoption reads the record again (`newChat`, the count of adoptions): the hint that one tab
///   showed is `shown` in the app's records, so it is done before the next tab takes the page.
/// Chromium does the same job the same way: a promo's record is the profile's, in the browser
/// process (the feature engagement tracker), and the page asks for a help bubble only once its
/// anchor is visible in the active window; a preloaded page triggers none.
export const CLOUD_CHAT_HINT_ID = "cloud-chat";

/// `unknown`: the record has not been read yet (nothing shows); `open`: no record, the page may ask
/// the app for it; `shown`: the app granted it to this new chat; `done`: it showed, was closed or
/// used, the app refused it to this page, or the app keeps no records.
export type CloudChatHintRecord = "unknown" | "open" | "shown" | "done";

/// The record of `records` for the hint: a record of any kind is done.
export function cloudChatHintRecord(records: Readonly<Record<string, string>> | undefined): CloudChatHintRecord {
  if (!records) return "done";
  return records[CLOUD_CHAT_HINT_ID] === undefined ? "open" : "done";
}

type CloudChatHintFacts = {
  record: CloudChatHintRecord;
  tipsOn: boolean;
  cloudOffered: boolean;
  cloudPicked: boolean;
  started: boolean;
};

/// Tips are on, Cloud is offered to this new chat (no session yet, not a chat on another machine)
/// and is not already its mode.
const cloudChatHintFits = (facts: CloudChatHintFacts) =>
  facts.tipsOn && facts.cloudOffered && !facts.cloudPicked && !facts.started;

/// Whether the page asks the app for the hint now: its record is open and the moment fits.
export function cloudChatHintDue(facts: CloudChatHintFacts): boolean {
  return facts.record === "open" && cloudChatHintFits(facts);
}

/// Whether the hint shows now: the app granted it and the moment still fits.
export function cloudChatHintShown(facts: CloudChatHintFacts): boolean {
  return facts.record === "shown" && cloudChatHintFits(facts);
}

export type CloudChatHintState = {
  record: CloudChatHintRecord;
  /// Asks the app to show it (once per page): `shown` on a yes, `done` on a no.
  claim(): void;
  /// The X: never again on this install.
  close(): void;
  /// Cloud was picked (any path): never again on this install.
  used(): void;
};

/// The record after a read of the app's records answered `read`. A record never goes from done back
/// to open, and a hint the app granted (`shown`) stays until the app's records have it: a read that
/// the page sent before its claim can answer after it.
export function cloudChatHintAfterRead(current: CloudChatHintRecord, read: CloudChatHintRecord): CloudChatHintRecord {
  return current === "done" || (current === "shown" && read === "open") ? current : read;
}

/// The record `chat` (the page's new chat now) sees: a hint the app granted to another new chat of
/// this page is done here, in the same render that shows this chat. No frame of the next tab draws
/// the hint of the tab before it.
function recordFor(held: { record: CloudChatHintRecord; chat: number }, chat: number): CloudChatHintRecord {
  return held.record === "shown" && held.chat !== chat ? "done" : held.record;
}

/// Reads the hint's record (the page's `tips.state {}`) when the page loads and again for each new
/// chat it shows (`newChat`: the count of the page's adoptions, so also an adoption that keeps the
/// screen mounted), so a hint this or another pane showed, closed or used is gone from the next new
/// chat here too, also when that chat is the next tab that takes this page from the spare pool;
/// writes `closed` or `used` once. A record never goes from done back to open, and a page whose
/// record is done reads no more.
export function useCloudChatHint(host: TipHost, newChat: number = 0): CloudChatHintState {
  const [held, setHeld] = useState<{ record: CloudChatHintRecord; chat: number }>({ record: "unknown", chat: newChat });
  const record = recordFor(held, newChat);
  /// The page's new chat now, for an answer of the app that comes after the page changed hands.
  const chatNow = useRef(newChat);
  chatNow.current = newChat;
  /// The app's records have the hint, or keep none: nothing is left to read.
  const settled = useRef(false);
  const written = useRef(false);
  const claimed = useRef(false);
  useEffect(() => {
    if (settled.current) return;
    let live = true;
    void host.read().then(
      (state) => {
        if (!live) return;
        const read = cloudChatHintRecord(state.records);
        if (read === "done") settled.current = true;
        setHeld((current) => ({ record: cloudChatHintAfterRead(recordFor(current, newChat), read), chat: newChat }));
      },
      () => {
        if (!live) return;
        settled.current = true;
        setHeld({ record: "done", chat: newChat });
      },
    );
    return () => {
      live = false;
    };
  }, [host, newChat]);
  const keep = useCallback(
    (state: "closed" | "used") => {
      settled.current = true;
      setHeld((current) => ({ ...current, record: "done" }));
      if (written.current) return;
      written.current = true;
      void host.write(CLOUD_CHAT_HINT_ID, state).catch(() => undefined);
    },
    [host],
  );
  const claim = useCallback(() => {
    if (claimed.current) return;
    claimed.current = true;
    // The yes is for the new chat the page shows when the app answers. The page's adoption by a tab
    // can still be on its way when the page takes the keyboard and asks: the hint is that tab's.
    const grant = (granted: boolean) => {
      if (!granted) settled.current = true;
      setHeld((current) =>
        current.record === "open" && granted
          ? { record: "shown", chat: chatNow.current }
          : { ...current, record: "done" },
      );
    };
    void host.claim(CLOUD_CHAT_HINT_ID, undefined).then(grant, () => grant(false));
  }, [host]);
  const close = useCallback(() => keep("closed"), [keep]);
  const used = useCallback(() => keep("used"), [keep]);
  return { record, claim, close, used };
}

/// The page the hint lives in, as `pageKey.ts` knows it: whether the person is at it now, and a
/// watch of that. A spare page in the pool is not key; neither is a tab in the background.
export type CloudChatHintPage = { key(): boolean; watch(run: () => void): () => void };

const thisPage: CloudChatHintPage = { key: () => pageIsKey(), watch: (run) => watchPageKey(run) };

/// Asks the app for the hint (`claim`) once it is `due` AND the person is at this page. A page that
/// is due while nobody sees it (a spare in the pool, a tab in the background) waits for the page's
/// key state (`pageKey.ts`, the page's one projection of it: no listener of its own, no timer, no
/// read) and draws nothing meanwhile; the watch goes when the hint is no longer due.
export function useCloudChatHintClaim(due: boolean, claim: () => void, page: CloudChatHintPage = thisPage): void {
  useEffect(() => {
    if (!due) return;
    if (page.key()) return claim();
    return page.watch(() => {
      if (page.key()) claim();
    });
  }, [due, claim, page]);
}
