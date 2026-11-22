// A skill's `/name` in a sent prompt (PromptText.tsx, ComposerQueue.tsx): the composer's command
// blue, and with a description, assistive tech hears it as the word's description. The word shows
// its own text, so it has no tooltip (c0ecbb88). The word is not a control, so it takes no focus.

export function SkillWord({ word, description }: { word: string; description: string }) {
  return description ? (
    <span className="cv-skill-word" aria-description={description}>
      {word}
    </span>
  ) : (
    <span className="cv-skill-word">{word}</span>
  );
}
