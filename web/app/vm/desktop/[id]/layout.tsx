// The desktop wrapper lives outside the [locale] tree (like /billing) so the
// URL a person keeps in a pane never gets rewritten by next-intl; it carries
// its own html/body per the out-of-locale layout requirement.
export default function VmDesktopLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body style={{ margin: 0, background: "#101418" }}>{children}</body>
    </html>
  );
}
