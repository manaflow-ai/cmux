import type { Metadata, Viewport } from "next";

export const metadata: Metadata = {
  title: "cmux Upgrade",
  description: "cmux upgrade pricing inside the cmux app.",
};

export const viewport: Viewport = {
  themeColor: "transparent",
};

// Nested layout under the root layout (web/app/layout.tsx), which already
// renders <html>/<body> with the Geist font variables. Rendering another
// <html> here nests it inside <body> and breaks hydration, so this layout
// only contributes the transparent-background overrides the in-app pricing
// webview needs; the page applies the appearance/background query params on
// top of these light-theme defaults.
export default function AppPricingLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <style>{`
        :root {
          --background: transparent;
          --foreground: #171717;
          --muted: #5f6368;
          --border: rgba(0, 0, 0, 0.14);
          --code-bg: rgba(245, 245, 245, 0.78);
          --button-foreground: #ffffff;
        }
        html, body { background: transparent !important; }
      `}</style>
      {children}
    </>
  );
}
