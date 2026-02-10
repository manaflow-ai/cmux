"use client";

import { useEffect, useState } from "react";
import { useDevValues } from "./components/spacing-control";

const phrases = [
  "coding agents",
  "multitasking",
  "Claude Code",
  "Codex",
  "OpenCode",
  "Gemini CLI",
];

export function TypingTagline() {
  const [phraseIndex, setPhraseIndex] = useState(0);
  const [charIndex, setCharIndex] = useState(0);
  const [deleting, setDeleting] = useState(false);
  const dev = useDevValues();

  useEffect(() => {
    const phrase = phrases[phraseIndex];

    if (!deleting && charIndex === phrase.length) {
      const timeout = setTimeout(() => setDeleting(true), 2000);
      return () => clearTimeout(timeout);
    }

    if (deleting && charIndex === 0) {
      const timeout = setTimeout(() => {
        setDeleting(false);
        setPhraseIndex((i) => (i + 1) % phrases.length);
      }, 0);
      return () => clearTimeout(timeout);
    }

    const speed = deleting ? 30 : 60;
    const timeout = setTimeout(() => {
      setCharIndex((c) => c + (deleting ? -1 : 1));
    }, speed);

    return () => clearTimeout(timeout);
  }, [charIndex, deleting, phraseIndex]);

  const phrase = phrases[phraseIndex];
  const displayed = phrase.slice(0, charIndex);

  return (
    <span>
      {displayed}
      <span
        className={`inline-block w-[2px] h-[1.1em] bg-foreground/70 ml-[1px] ${dev.cursorBlink ? "animate-blink" : ""}`}
        style={{ position: "relative", top: `${dev.cursorTop}px` }}
      />
    </span>
  );
}
