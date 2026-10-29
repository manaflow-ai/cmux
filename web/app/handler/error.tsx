"use client";

import { RouteErrorView } from "../components/error-boundary";

/** Sign-in pages depend on Hexclave; its outage must not blank the tab. */
export default function HandlerError({ error, reset, retry }: { error: Error; reset: () => void; retry?: () => void }) {
  return <RouteErrorView boundary="handler-route" error={error} retry={retry ?? reset} />;
}
