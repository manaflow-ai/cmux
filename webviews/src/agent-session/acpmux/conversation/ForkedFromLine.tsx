// The one line in a fork's transcript where its parent's history ends ("Forked from <chat>.
// Everything above is from that chat.", direct.ts `forked`), with the chat's name as the session
// link chip a sender's name is (AgentTag.tsx): a click opens the chat it was forked from beside
// this one (`openSender`, `chat.offer.open`), and its hover card says how that chat stands (#50086;
// Leo, 2026-11-22: "i also do wonder about the state of affairs of our forking behaviour and if
// it's as good as it can be"). A fork of a subagent ("Forked from <subagent> of <chat>.") links
// the chat the same way. The line's words stay the row's `text`, so Find and Copy read them.
import { useContext } from "react";
import { useT } from "../i18n";
import { SubsessionContext } from "../subagents/subsessions";
import { useSessionHover } from "../started/useSessionHover";
import { openSessionAttributes } from "./menuParts";
import { AgentTag } from "./AgentTag";
import type { ForkedFrom } from "../model";
import "./ForkedFromLine.css";

/// `text` cut around the chat's name, its last mention (a subagent's name, before it, may hold it
/// too); none when the text does not name it.
export function forkedFromParts(text: string, chat: string): [string, string] | undefined {
  if (!chat) return undefined;
  const at = text.lastIndexOf(chat);
  return at < 0 ? undefined : [text.slice(0, at), text.slice(at + chat.length)];
}

export function ForkedFromLine({ text, forkedFrom }: { text: string; forkedFrom: ForkedFrom }) {
  const t = useT();
  const chats = useContext(SubsessionContext);
  const open = chats?.openSender ?? chats?.open;
  const { trigger, card } = useSessionHover(forkedFrom.parentId, open);
  const parts = forkedFromParts(text, forkedFrom.chat);
  if (!parts || !open) return <div className="acpmux-muted">{text}</div>;
  const [before, after] = parts;
  const label = t("subagents.open", { name: forkedFrom.chat });
  return (
    <div className="acpmux-muted cv-forked-from" data-forked-from={forkedFrom.parentId}>
      {before}
      <AgentTag
        name={forkedFrom.chat}
        className="cv-forked-from__chat"
        ariaLabel={label}
        title={label}
        hover={trigger}
        attributes={openSessionAttributes(forkedFrom.parentId, chats?.openSender !== undefined)}
        onClick={(event) => {
          event.stopPropagation();
          open(forkedFrom.parentId);
        }}
      />
      {after}
      {card}
    </div>
  );
}
