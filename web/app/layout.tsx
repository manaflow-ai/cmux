// Root layout: provides required <html>/<body> tags for Next.js 16.
// The locale-specific layout in app/[locale]/layout.tsx overrides these
// with lang, dir, fonts, and providers.

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html suppressHydrationWarning>
      <body>{children}</body>
    </html>
  );
}
