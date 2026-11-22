import { useId } from "react";
import { Markdown } from "./conversation/Markdown";
import { useT } from "./i18n";
import { type PastTurn } from "./pastChatModel";
export function PastChat({ turns, githubRepository }: { turns: PastTurn[]; githubRepository?: string }) {
  const t = useT();
  const labelId = useId();
  return (
    <section className="acpmux-past-chat" aria-labelledby={labelId}>
      <p className="acpmux-past-chat-label" id={labelId}>
        {t("pastChat.label")}
      </p>
      {turns.map((turn, index) => (
        <div className="acpmux-past-chat-turn" key={index}>
          <div className="cv-user">
            <div className="ui-glass cv-user__bubble selectable">{turn.prompt}</div>
          </div>
          {turn.answer && (
            <Markdown className="selectable" {...(githubRepository ? { githubRepository } : {})}>
              {turn.answer}
            </Markdown>
          )}
        </div>
      ))}
    </section>
  );
}
