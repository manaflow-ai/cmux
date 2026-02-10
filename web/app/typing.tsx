"use client";

import { useEffect, useState } from "react";

const phrases = [
  "coding agents",
  "multitasking",
  "Claude Code",
  "Codex",
  "Opencode",
  "Gemini",
];

export function TypingTagline() {
  const [phraseIndex, setPhraseIndex] = useState(0);
  const [charIndex, setCharIndex] = useState(0);
  const [deleting, setDeleting] = useState(false);
  const [showControls, setShowControls] = useState(false);
  const [topOffset, setTopOffset] = useState(0);
  const [blink, setBlink] = useState(true);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "." && e.metaKey) {
        e.preventDefault();
        setShowControls((s) => !s);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  useEffect(() => {
    const phrase = phrases[phraseIndex];

    if (!deleting && charIndex === phrase.length) {
      const timeout = setTimeout(() => setDeleting(true), 2000);
      return () => clearTimeout(timeout);
    }

    if (deleting && charIndex === 0) {
      setDeleting(false);
      setPhraseIndex((i) => (i + 1) % phrases.length);
      return;
    }

    const speed = deleting ? 30 : 60;
    const timeout = setTimeout(() => {
      setCharIndex((c) => c + (deleting ? -1 : 1));
    }, speed);

    return () => clearTimeout(timeout);
  }, [charIndex, deleting, phraseIndex]);

  const phrase = phrases[phraseIndex];
  const displayed = phrase.slice(0, charIndex);
  const tailwindClass =
    topOffset > 0
      ? `-top-[${topOffset}px]`
      : topOffset < 0
        ? `top-[${Math.abs(topOffset)}px]`
        : "";

  return (
    <span>
      {displayed}
      <span
        className={`inline-block w-[2px] h-[1.1em] bg-foreground/70 ml-[1px] ${blink ? "animate-blink" : ""}`}
        style={{ position: "relative", top: `${-topOffset}px` }}
        onDoubleClick={() => setShowControls((s) => !s)}
      />
      {showControls && (
        <span className="fixed bottom-5 right-5 z-50 flex w-[420px] items-center gap-3 rounded-xl bg-[#222] px-4 py-3 font-mono text-xs text-white shadow-lg">
          <label className="flex items-center gap-2">
            top:
            <input
              type="range"
              min={-5}
              max={5}
              step={0.5}
              value={topOffset}
              onChange={(e) => setTopOffset(parseFloat(e.target.value))}
              className="w-24"
            />
            <span className="w-12">{topOffset}px</span>
          </label>
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={blink}
              onChange={(e) => setBlink(e.target.checked)}
            />
            blink
          </label>
          <code className="select-all cursor-pointer rounded bg-[#333] px-2 py-0.5">
            {tailwindClass || "0px"}
          </code>
        </span>
      )}
    </span>
  );
}
