"use client";

import { useServerInsertedHTML } from "next/navigation";
import { useRef } from "react";

export function ThemeBootstrapScript({ script }: { script: string }) {
  const insertedRef = useRef(false);

  useServerInsertedHTML(() => {
    if (insertedRef.current) return null;
    insertedRef.current = true;

    // next/script queues inline App Router scripts for the client bootstrap,
    // which is too late for this first-paint theme bootstrap.
    return (
      /* oxlint-disable-next-line react-doctor/nextjs-no-native-script */
      <script
        id="cmux-theme-bootstrap"
        dangerouslySetInnerHTML={{ __html: script }}
      />
    );
  });

  return null;
}
