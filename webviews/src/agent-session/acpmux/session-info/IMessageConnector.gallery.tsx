// l10n-allow-file: synthetic contact names, handles and state labels for gallery fixtures.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { useT } from "../i18n";
import { IMessageConnector, type IMessageLook } from "./IMessageConnector";
import { IMESSAGE_INITIAL, type IMessageData, type IMessageThread } from "./imessage";
import { SessionInfoPanel } from "./SessionInfo";
import { SessionInfoSection } from "./SessionInfoSection";

const THREADS: IMessageThread[] = [
  { chat_id: 8, title: "Maya Chen", is_group: false, participants: ["maya@example.test"] },
  { chat_id: 7, title: "Friday dinner", is_group: true, participants: ["Maya", "Sam", "You"] },
  { chat_id: 6, title: "+1 (415) 555-0123", is_group: false, participants: ["+14155550123"] },
  { chat_id: 5, title: "Alex, Jordan", is_group: true, participants: ["Alex", "Jordan"] },
];
type Props = {
  status: IMessageData["status"];
  look?: IMessageLook;
  error?: string;
  sends?: boolean;
};

function GalleryIMessage({ status, look, error, sends = true }: Props) {
  const t = useT();
  const [sectionOpen, setSectionOpen] = useState(true);
  const [data, setData] = useState<IMessageData>({
    ...IMESSAGE_INITIAL,
    status,
    error: error ?? null,
    sends_enabled: sends,
    threads: status === "connected" && !error ? THREADS : [],
  });
  const [expanded, setExpanded] = useState(status === "connected");
  return (
    <div className="acpmux-shell" style={{ height: "100%", display: "flex", justifyContent: "flex-end" }}>
      <SessionInfoPanel width={320} placement="overlay">
        <SessionInfoSection
          id="connectors"
          title={t("rail.connectors")}
          open={sectionOpen}
          onOpenChange={setSectionOpen}
        >
          <ul className="acpmux-session-info-list">
            <IMessageConnector
              look={look}
              view={{
                data,
                expanded,
                busy: false,
                toggle: () => setExpanded((was) => !was),
                perform: async (action) => {
                  const next =
                    action === "disconnect"
                      ? "not_connected"
                      : action === "connect"
                        ? "needs_full_disk_access"
                        : action === "full_disk_access"
                          ? "needs_automation"
                          : "connected";
                  setExpanded(next === "connected");
                  setData({
                    ...IMESSAGE_INITIAL,
                    status: next,
                    sends_enabled: action !== "skip_automation",
                    threads: next === "connected" ? THREADS : [],
                  });
                },
              }}
            />
          </ul>
        </SessionInfoSection>
      </SessionInfoPanel>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.imessage-connector",
  title: "Connect iMessage",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 320, normal: 420 },
  covers: ["agent-session/acpmux/session-info/IMessageConnector.tsx"],
  load: async () => GalleryIMessage,
  variants: {
    "not-connected": {
      props: { status: "not_connected" },
      note: "The default-visible Mac connector: one compact Connect action; no Messages data has been read.",
    },
    "full-disk-access": {
      props: { status: "needs_full_disk_access" },
      note: "The first permission step opens Full Disk Access directly; activation refreshes status without polling.",
    },
    automation: {
      props: { status: "needs_automation" },
      note: "Messages Automation is needed for sends. Skip continues with reading only.",
    },
    "connected-list": {
      props: { status: "connected", look: "list" },
      note: "Shipped: contacts and group chats interleave newest first. Quiet icons distinguish people and groups; the names share one column.",
    },
    "connected-grouped": {
      props: { status: "connected", look: "grouped" },
      note: "Alternative: people followed by groups. Rejected because grouping loses the shared newest-first order.",
    },
    "connected-details": {
      props: { status: "connected", look: "details" },
      note: "Alternative: participant handles below every group. Rejected as the default because it repeats names and lengthens the connector.",
    },
    "connected-read-only": {
      props: { status: "connected", sends: false },
      note: "Automation skipped: real threads remain available, with an explicit permission action for future sends.",
    },
    "database-missing": {
      props: { status: "connected", error: "missing" },
      note: "Messages has not created chat.db: a concrete recovery and Retry, with Disconnect still available.",
    },
    unavailable: {
      props: { status: "not_connected", error: "unavailable" },
      note: "The native reader could not load: the row stays visible and Connect can be tried again.",
    },
  },
});
