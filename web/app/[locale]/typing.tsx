"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { useDevValues } from "./components/spacing-control";

function usePhrases() {
  const t = useTranslations("home");
  return [
    t("typingCodingAgents"),
    t("typingMultitasking"),
    "Claude Code",
    "Codex",
    "OpenCode",
    "Gemini CLI",
  ];
}

// Demo mode (screenshots/marketing only): with `?demo` in the URL, the tagline
// is pinned to "multitasking" with no typing animation and no blinking cursor.
// Off by default; production behavior is unchanged when the flag is absent.
// Read once via a lazy initializer (no effect): in normal use the flag is absent
// so server and client agree; it only differs when explicitly taking screenshots.
function useDemoMode() {
  const [demo] = useState(
    () =>
      typeof window !== "undefined" &&
      new URLSearchParams(window.location.search).has("demo"),
  );
  return demo;
}

export function TypingTagline() {
  const phrases = usePhrases();
  const demoMode = useDemoMode();
  const [phraseIndex, setPhraseIndex] = useState(0);
  const [charIndex, setCharIndex] = useState(0);
  const [deleting, setDeleting] = useState(false);
  const dev = useDevValues();

  useEffect(() => {
    if (demoMode) return;
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
  }, [charIndex, deleting, phraseIndex, demoMode]);

  if (demoMode) {
    return <span>{phrases[1]}</span>;
  }

  const phrase = phrases[phraseIndex];
  const displayed = phrase.slice(0, charIndex);

  return (
    <span>
      <span>{displayed}</span>
      <span
        className={`inline-block w-[2px] h-[1.1em] bg-foreground/70 ml-[1px] ${dev.cursorBlink ? "animate-blink" : ""}`}
        style={{ position: "relative", top: `${dev.cursorTop}px` }}
      />
    </span>
  );
}
