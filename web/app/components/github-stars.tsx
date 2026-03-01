"use client";

import { useEffect, useState } from "react";
import posthog from "posthog-js";

function formatStars(count: number): string {
  if (count >= 1000) {
    const k = count / 1000;
    return k % 1 === 0 ? `${k}k` : `${k.toFixed(1)}k`;
  }
  return String(count);
}

export function GitHubStarsBadge() {
  const [stars, setStars] = useState<number | null>(null);

  useEffect(() => {
    fetch("/api/github-stars")
      .then((r) => r.json())
      .then((d) => {
        if (d.stars != null) setStars(d.stars);
      })
      .catch(() => {});
  }, []);

  if (stars === null) return null;

  return (
    <a
      href="https://github.com/manaflow-ai/cmux"
      target="_blank"
      rel="noopener noreferrer"
      onClick={() =>
        posthog.capture("cmuxterm_github_clicked", { location: "stars_badge" })
      }
      className="inline-flex items-center gap-1.5 pr-2 text-sm text-muted hover:text-foreground transition-colors"
    >
      <svg
        width="16"
        height="16"
        viewBox="0 0 24 24"
        fill="currentColor"
        aria-hidden="true"
      >
        <path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" />
      </svg>
      <span className="text-xs tabular-nums">{formatStars(stars)}</span>
    </a>
  );
}
