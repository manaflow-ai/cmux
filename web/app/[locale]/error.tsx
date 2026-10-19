"use client";

import { RouteErrorView } from "../components/error-boundary";

/** Keeps the locale layout mounted when a landing, legal, or docs page throws. */
export default function LocaleError({ error, reset, retry }: { error: Error; reset: () => void; retry?: () => void }) {
  return <RouteErrorView boundary="locale-route" error={error} retry={retry ?? reset} />;
}
