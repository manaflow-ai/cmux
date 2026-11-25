import { SessionMark } from "../shared/AgentMark";
import { newestFormerName } from "./AgentIdentityChip";
import { Bot } from "./conversation/icons";
import type { IncomingRelation } from "./conversation/incomingMessage";
import { useT, type StringKey } from "./i18n";
import type { SenderIdentity } from "./senderIdentity";
import "./senderIdentity.css";

const RELATIONS: Record<IncomingRelation, StringKey> = {
  parent: "message.from.parent",
  subsession: "message.from.subsession",
  ancestor: "message.from.ancestor",
  descendant: "message.from.descendant",
};

/** Session first, machine second. Also used inside a sender chip without drawing a second mark. */
export function SenderIdentityLabel({
  identity,
  mark = true,
  describe = true,
}: {
  identity: SenderIdentity;
  mark?: boolean;
  describe?: boolean;
}) {
  const t = useT();
  const name = !describe
    ? identity.name
    : identity.relation
      ? t(RELATIONS[identity.relation], { name: identity.name })
      : identity.known
        ? t("sender.otherSession", { name: identity.name })
        : identity.name;
  // The name it had before its last rename, on the name's tooltip (AgentIdentityChip.tsx's rule).
  const former = newestFormerName(identity.name, identity.formerNames);
  return (
    <span className="acpmux-sender" data-relation={identity.relation}>
      {mark && <SessionMark icon={identity.icon} agent={identity.harness} size={14} fallback={<Bot size={14} />} />}
      <span className="acpmux-sender__name" title={former ? t("identity.fka", { name: former }) : undefined}>
        {name}
      </span>
      {identity.host && <span className="acpmux-sender__host">{identity.host}</span>}
    </span>
  );
}
