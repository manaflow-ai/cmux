// The one Sign In button of first-party pages (Lawrence, msg 3790: "everywhere we say sign in, we need
// to have a button for signing in"), the web twin of the app's SignInButton: the surface's solid
// primary button on the control scale, marked `data-action="sign-in"`. The page gives the words (its
// own string table) and what a click does (the app's `palette.auth.signIn`, through the page's store).
import { Button, type ButtonSize } from "./Button";

export interface SignInButtonProps {
  /** The localized title, "Sign In". */
  label: string;
  onSignIn: () => void;
  /** md (28) next to a line of text; lg (32) on a roomy page. */
  size?: ButtonSize;
  className?: string;
}

export function SignInButton({ label, onSignIn, size = "md", className }: SignInButtonProps) {
  return (
    <Button variant="solid" size={size} className={className} data-action="sign-in" onClick={onSignIn}>
      {label}
    </Button>
  );
}
