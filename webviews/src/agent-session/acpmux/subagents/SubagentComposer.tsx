// A subagent's own pane ends in a composer for that subagent (Leo, 2026-11-03: "currently it says
// "read only" on the subagents in cmux-next. we should improve that"). The subagent has no acpmux
// session of its own, so what is typed here goes to the chat it belongs to as a relay its agent
// passes on (subagentMessage.ts); the placeholder names the subagent and the line under the box
// names the chat, so a prompt never goes anywhere the composer does not say. It is the one composer
// box (ComposerBox.tsx) with the prompt and Send only: the chat's queue, pull request bar, model and
// mode chips are the chat's, and drawing them here sent edits to the chat (Leo 2026-10-20).
import { useState } from "react";
import { useT } from "../i18n";
import { ComposerBox } from "../ComposerBox";
import { ArrowUpIcon } from "../ComposerPickers";

export function SubagentComposer({
  subagent,
  chat,
  onSend,
}: {
  /// The subagent the prompt is for, as the pane names it.
  subagent: string;
  /// The chat that takes the prompt and passes it on.
  chat: string;
  /// Sends the typed message; unset while the chat takes no prompts (not connected, View Only).
  onSend?: (message: string) => Promise<unknown>;
}) {
  const t = useT();
  const [text, setText] = useState("");
  const [failed, setFailed] = useState<string>();
  const ready = Boolean(onSend) && text.trim().length > 0;
  const submit = () => {
    const message = text.trim();
    if (!onSend || !message) return;
    setText("");
    setFailed(undefined);
    onSend(message).catch((error: unknown) => {
      // The message comes back to the prompt, unless something new was typed meanwhile.
      setText((current) => (current ? current : message));
      setFailed(error instanceof Error && error.message ? error.message : t("subagents.messageFailed"));
    });
  };
  return (
    <form
      className="acpmux-composer acpmux-subagent-composer"
      data-composer-grid=""
      data-cmux-component="SubagentComposer"
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      {failed && (
        <p className="acpmux-composer-remote-note" role="alert">
          {failed}
        </p>
      )}
      <ComposerBox
        field={{
          className: "acpmux-composer-prompt",
          value: text,
          placeholder: t("subagents.messagePlaceholder", { name: subagent }),
          attributes: { role: "textbox", "aria-label": t("subagents.messagePlaceholder", { name: subagent }) },
          onChange: (markdown) => setText(markdown),
          onSubmit: () => submit(),
        }}
        attachments={[]}
        setAttachments={() => undefined}
        onRemoveAttachment={() => undefined}
        fieldMenu={[]}
        chromeItems={[]}
        trailing={
          <button
            type="submit"
            className={`acpmux-send${ready ? " acpmux-send-ready" : ""}`}
            disabled={!onSend}
            aria-label={t("subagents.messageSend", { name: subagent })}
            // tooltip-allow: names the icon-only Send and the subagent it goes to.
            title={t("subagents.messageSend", { name: subagent })}
          >
            <ArrowUpIcon />
          </button>
        }
        // The quiet row's middle names the chat that passes the message on (where the chat's own
        // composer draws its look dots).
        bottom={<span className="cv-subagent-composer-via">{t("subagents.messageVia", { name: chat })}</span>}
      />
    </form>
  );
}
