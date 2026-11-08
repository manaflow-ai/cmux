import { useCallback, useEffect, useRef, useState } from "react";
import type { TipHost } from "../../ui/featureTips/store";

/// The one-time Cloud hint over a new chat's composer (CloudChatHint.tsx). Leo, 2026-11-08, on
/// teammates starting a Cloud chat: "how would they know?". It says a chat can run in Cloud, with
/// Use Cloud (the Where menu's own Cloud pick) and an X.
///
/// Its record is the app's, as the feature tips' are (`tips.state`, Swift
/// `AgentPaneFeatureTipRecords`, the app's UserDefaults for the life of the install; never a page's
/// own storage, which ends with the launch). It shows until the person closes it (`closed`) or
/// picks Cloud by any path (`used`): the hint, the Where menu, or New Cloud Chat in the palette.
/// It takes no claim on the tips' 14-day budget: it is a line in the new chat's own flow, not a
/// callout over work. An app that keeps no records shows no hint, since a hint that could not stay
/// closed must not show at all; neither does an install whose feature tips are off.
export const CLOUD_CHAT_HINT_ID = "cloud-chat";

/// `unknown`: the record has not been read yet (nothing shows); `open`: no record, the hint may
/// show; `done`: closed or used, or the app keeps no records.
export type CloudChatHintRecord = "unknown" | "open" | "done";

/// The record of `records` for the hint: a record of any kind is done.
export function cloudChatHintRecord(records: Readonly<Record<string, string>> | undefined): CloudChatHintRecord {
  if (!records) return "done";
  return records[CLOUD_CHAT_HINT_ID] === undefined ? "open" : "done";
}

/// Whether the hint shows now: its record is open, tips are on, Cloud is offered to this new chat
/// (no session yet, not a chat on another machine) and is not already its mode.
export function cloudChatHintShown(facts: {
  record: CloudChatHintRecord;
  tipsOn: boolean;
  cloudOffered: boolean;
  cloudPicked: boolean;
  started: boolean;
}): boolean {
  return facts.record === "open" && facts.tipsOn && facts.cloudOffered && !facts.cloudPicked && !facts.started;
}

export type CloudChatHintState = {
  record: CloudChatHintRecord;
  /// The X: never again on this install.
  close(): void;
  /// Cloud was picked (any path): never again on this install.
  used(): void;
};

/// Reads the hint's record (the page's `tips.state {}`) when the page loads and again for each new
/// chat it shows (`newChat`, the New Tab page's generation), so a hint another pane closed or used
/// is gone from the next new chat here too; writes `closed` or `used` once. A record never goes from
/// done back to open.
export function useCloudChatHint(host: TipHost, newChat: number = 0): CloudChatHintState {
  const [record, setRecord] = useState<CloudChatHintRecord>("unknown");
  const written = useRef(false);
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
  const close = useCallback(() => keep("closed"), [keep]);
  const used = useCallback(() => keep("used"), [keep]);
  return { record, close, used };
}
