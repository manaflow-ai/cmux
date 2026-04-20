"use client";

import { useEffect } from "react";

export function OpenNativeClient({ href }: { href: string }) {
  useEffect(() => {
    window.location.href = href;
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
      <div style={{ maxWidth: 420, textAlign: "center" }}>
        <h1 style={{ fontSize: 22, fontWeight: 600, margin: "0 0 12px" }}>
          Signed in to cmux
        </h1>
        <p style={{ color: "#555", lineHeight: 1.5, margin: "0 0 20px" }}>
          Returning you to the app.
        </p>
        <p style={{ fontSize: 13, color: "#888" }}>
          If cmux didn&apos;t open, <a href={href}>click here to return to it</a>.
        </p>
      </div>
    </div>
  );
}
