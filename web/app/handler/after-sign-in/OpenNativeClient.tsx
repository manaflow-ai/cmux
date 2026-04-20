"use client";

import { useEffect, useRef } from "react";

export function OpenNativeClient({ href }: { href: string }) {
  const firedRef = useRef(false);

  useEffect(() => {
    if (firedRef.current) return;
    firedRef.current = true;
    // Fire the deeplink in a hidden iframe so the current tab stays put on
    // the success message instead of unloading into a "did you mean to open
    // cmux?" handoff page.
    const iframe = document.createElement("iframe");
    iframe.style.display = "none";
    iframe.src = href;
    document.body.appendChild(iframe);
    return () => {
      iframe.remove();
    };
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
          It&apos;s safe to close this window. cmux should have the rest.
        </p>
        <p style={{ fontSize: 13, color: "#888" }}>
          If cmux didn&apos;t open, <a href={href}>click here to return to it</a>.
        </p>
      </div>
    </div>
  );
}
