import type { ComponentProps } from "react";
import { useNewTabModules } from "./newTabLoader";

// The New Tab screens drawn from their own chunk, once it has loaded (newTabLoader.ts).

type ScreenProps = ComponentProps<typeof import("./NewTabScreen").NewTabScreen>;
type PageProps = ComponentProps<typeof import("../NewTabPage").NewTabPage>;

/// NewTabScreen from its chunk: nothing until the chunk has loaded.
export function LazyNewTabScreen(props: ScreenProps) {
  const modules = useNewTabModules();
  return modules ? <modules.screen.NewTabScreen {...props} /> : null;
}

/// The classic NewTabPage from the same chunk: nothing until the chunk has loaded.
export function LazyNewTabPage(props: PageProps) {
  const modules = useNewTabModules();
  return modules ? <modules.page.NewTabPage {...props} /> : null;
}
