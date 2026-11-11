import { type ReactNode, useState } from "react";
import { useChiefFace } from "../chiefFace";
import { useT } from "../i18n";
import { useTranscriptChief } from "./sentFrom";
import { isLongPrompt } from "./chiefPromptBubbleModel";
import { ExpandRow } from "./ExpandRow";
/// The line over a prompt the Chief sent on the person's behalf, as ChatGPT marks a message its
/// agent sent: the Chief's existing avatar (chiefFace.ts) and a muted "Sent from <Chief>",
/// right-aligned with the bubble (Leo, 2026-11-02: "this is what the chatgpt dot does").
export function ChiefSentFrom() {
  const t = useT();
  const face = useChiefFace(useTranscriptChief());
  // l10n-allow: Chief is the product's name for it, never translated.
  const name = face?.name ?? "Chief";
  return (
    <div className="cv-user__from">
      {face?.src ? (
        <img className="cv-agent-avatar cv-user__from-avatar" src={face.src} alt="" width={14} height={14} />
      ) : face?.text ? (
        <span className="cv-chief-text-avatar cv-user__from-avatar" aria-hidden="true">
          {face.text}
        </span>
      ) : null}
      <span className="cv-user__from-label">{t("transcript.sentFrom", { name })}</span>
    </div>
  );
}

/// A prompt the Chief sent a subagent (its task, a tell, a restart message): marked "Sent from
/// <Chief>" (`ChiefSentFrom`) so it does not read as the person's own, and a long task shows its first
/// lines with Show all inside the bubble, as its whole bottom row, the way a long prompt's Show more
/// is (PromptText.tsx; Lawrence and Lucas, 2026-11-11 standup: "Show All here is ugly", "that should
/// be inside of the chat box"). The session keeps the whole text; copy and select still take all of
/// it when open. `actions` is the prompt's action row (copy, retry), under the bubble.
export function ChiefPromptBubble({ text, actions }: { text: string; actions?: ReactNode }) {
  const t = useT();
  const long = isLongPrompt(text);
  const [open, setOpen] = useState(false);
  const collapsed = long && !open;
  return (
    <>
      <ChiefSentFrom />
      <div
        className={
          collapsed
            ? "ui-glass cv-user__bubble cv-user__bubble--collapsed selectable"
            : "ui-glass cv-user__bubble selectable"
        }
      >
        {/* The clamp is on this inner box, not the bubble: clamped on the bubble, its bottom
            padding showed half of the next line (Leo 2026-10-31). */}
        {collapsed ? <div className="cv-user__clamp">{text}</div> : text}
        {long && (
          <ExpandRow
            open={open}
            label={open ? t("transcript.promptShowLess") : t("transcript.promptShowAll")}
            onToggle={() => setOpen(!open)}
            className="cv-user__more"
          />
        )}
      </div>
      {actions}
    </>
  );
}
