// A skill's `/name` in a sent prompt (PromptText.tsx, ComposerQueue.tsx): the composer's command
// blue, and with a description, a dotted underline on hover and the description as the app's
// tooltip above it (ui/titleTooltips.ts reads `data-tooltip`); assistive tech hears it as the word's
// description. The word is not a control, so it takes no focus.

export function SkillWord({ word, description }: { word: string; description: string }) {
  return description ? (
    <span className="cv-skill-word" data-tooltip={description} data-tooltip-side="top" aria-description={description}>
      {word}
    </span>
  ) : (
    <span className="cv-skill-word">{word}</span>
  );
}
