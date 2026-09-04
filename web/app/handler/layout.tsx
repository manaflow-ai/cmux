export const instant = false;

/**
 * cmux owns the auth screens under `/handler`, and they are plain server
 * components. The Stack provider now lives on the catch-all route that still
 * needs it, so signing in no longer downloads the auth SDK.
 */
export default function HandlerLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
