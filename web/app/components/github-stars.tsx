"use client";

import { useEffect, useState } from "react";

function formatStars(count: number): string {
  if (count >= 1000) {
    const k = count / 1000;
    return k % 1 === 0 ? `${k}k` : `${k.toFixed(1)}k`;
  }
  return String(count);
}

export function GitHubStars() {
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
    <span className="inline-flex items-center gap-1 text-xs tabular-nums text-muted">
      <svg
        width="12"
        height="12"
        viewBox="0 0 24 24"
        fill="currentColor"
        aria-hidden="true"
      >
        <path d="M12 .587l3.668 7.568L24 9.306l-6 5.847 1.417 8.26L12 19.446l-7.417 3.967L6 15.153 0 9.306l8.332-1.151z" />
      </svg>
      {formatStars(stars)}
    </span>
  );
}
