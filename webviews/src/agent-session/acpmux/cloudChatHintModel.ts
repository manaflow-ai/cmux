import { useCallback, useEffect, useRef, useState } from "react";
import type { TipHost } from "../../ui/featureTips/store";

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

/// Reads the hint's record (the page's `tips.state {}`) when the page loads and again for each new
/// chat it shows (`newChat`, the New Tab page's generation), so a hint this or another pane showed,
/// closed or used is gone from the next new chat here too; writes `closed` or `used` once. A record
/// never goes from done back to open.
export function useCloudChatHint(host: TipHost, newChat: number = 0): CloudChatHintState {
  const [record, setRecord] = useState<CloudChatHintRecord>("unknown");
  const written = useRef(false);
  const claimed = useRef(false);
  useEffect(() => {
    let live = true;
    void host.read().then(
      (state) => live && setRecord((current) => (current === "done" ? current : cloudChatHintRecord(state.records))),
      () => live && setRecord("done"),
    );
    return () => {
      live = false;
    };
  }, [host, newChat]);
  const keep = useCallback(
    (state: "closed" | "used") => {
      setRecord("done");
      if (written.current) return;
      written.current = true;
      void host.write(CLOUD_CHAT_HINT_ID, state).catch(() => undefined);
    },
    [host],
  );
  const claim = useCallback(() => {
    if (claimed.current) return;
    claimed.current = true;
    void host.claim(CLOUD_CHAT_HINT_ID, undefined).then(
      (granted) => setRecord((current) => (current === "open" && granted ? "shown" : "done")),
      () => setRecord("done"),
    );
  }, [host]);
  const close = useCallback(() => keep("closed"), [keep]);
  const used = useCallback(() => keep("used"), [keep]);
  return { record, claim, close, used };
}
