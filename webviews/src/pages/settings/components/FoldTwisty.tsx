// The chevron a Settings <details> draws in its summary, in place of the browser's marker: Settings'
// own twisty (the context menus' folders), pointing down open and right closed, turning on the settle
// as the body folds (styles.css `.fold-twisty`, agent-session/shared/FoldDetails.tsx).
import { Icon } from "../icons";

export function FoldTwisty() {
  return <Icon name="chevron" className="menu-twisty fold-twisty" />;
}
