"use client";

import dynamic from "next/dynamic";

const StackHandler = dynamic(
  () => import("@stackframe/stack").then((module) => module.StackHandler),
  {
    ssr: false,
    loading: () => <StackHandlerLoading />,
  },
);

const MagicLinkSignIn = dynamic(
  () => import("@stackframe/stack").then((module) => module.MagicLinkSignIn),
  {
    ssr: false,
    loading: () => <StackHandlerLoading />,
  },
);

export function ClientStackHandler() {
  return <StackHandler fullPage />;
}

export function ClientMagicLinkSignIn() {
  return <MagicLinkSignIn />;
}

function StackHandlerLoading() {
  return (
    <main
      aria-busy="true"
      className="flex min-h-screen items-center justify-center"
    >
      <div
        aria-hidden="true"
        className="h-5 w-5 animate-spin rounded-full border-2 border-current border-t-transparent"
      />
    </main>
  );
}
