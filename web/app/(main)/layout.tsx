import { SiteFooter } from "../components/nav-links";
import { DevPanel } from "../components/spacing-control";

export default function MainLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      {children}
      <SiteFooter />
      <DevPanel />
    </>
  );
}
