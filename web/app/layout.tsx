// Root layout: minimal pass-through. The actual layout with <html>/<body> is
// in app/[locale]/layout.tsx for localized routes and app/handler/layout.tsx
// for Stack Auth handler routes.

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
