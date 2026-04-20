"use client";

import { useEffect } from "react";

const AUTO_RETURN_MS = 2000;

export function OpenNativeClient({ href }: { href: string }) {
  useEffect(() => {
    const id = window.setTimeout(() => {
      window.location.href = href;
    }, AUTO_RETURN_MS);
    return () => window.clearTimeout(id);
  }, [href]);

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        minHeight: "100vh",
        padding: 24,
        fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, sans-serif",
      }}
    >
      <div style={{ maxWidth: 440, textAlign: "center" }}>
        <h1 style={{ fontSize: 24, fontWeight: 600, margin: "0 0 12px" }}>
          Signed in to cmux
        </h1>
        <p style={{ color: "#555", lineHeight: 1.5, margin: "0 0 24px" }}>
          You can close this window.
        </p>
        <a
          href={href}
          style={{
            display: "inline-block",
            padding: "10px 18px",
            borderRadius: 8,
            background: "#111",
            color: "#fff",
            textDecoration: "none",
            fontSize: 14,
            fontWeight: 500,
          }}
        >
          Return to cmux
        </a>
      </div>
    </div>
  );
}
