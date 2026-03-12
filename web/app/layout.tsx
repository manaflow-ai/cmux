// Root layout: minimal pass-through. The actual layout with <html>/<body> is
// in app/[locale]/layout.tsx, which sets lang, dir, and wraps with i18n provider.

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
