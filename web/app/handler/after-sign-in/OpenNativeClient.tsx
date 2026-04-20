"use client";

import { useEffect } from "react";

export function OpenNativeClient({ href }: { href: string }) {
  useEffect(() => {
    window.location.href = href;
  }, [href]);

  return (
    <div style={{ padding: 40, textAlign: "center", fontFamily: "system-ui" }}>
      <p>Redirecting to cmux...</p>
      <p style={{ fontSize: 14, color: "#666", marginTop: 8 }}>
        If the app doesn&apos;t open,{" "}
        <a href={href}>click here</a>.
      </p>
    </div>
  );
}
