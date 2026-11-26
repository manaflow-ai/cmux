// The one Sign In button of first-party pages (Lawrence, msg 3790: "everywhere we say sign in, we need
// to have a button for signing in"), the web twin of the app's SignInButton: the surface's solid
// primary button on the control scale, marked `data-action="sign-in"`. The page gives the words (its
// own string table) and what a click does (the app's `palette.auth.signIn`, through the page's store).
//
// `backend` is the line under it saying what it signs in to ("Signs in to cmux.com", "Signs in to
// Development backend · dev-abc.cmux.dev"; Leo: "why is the stuff so weird to log in to dev builds?").
// The app makes it (Rust's `backend_label`) and sends it in the page's own state; the page never
// works it out.
import { Button, type ButtonSize } from "./Button";

export interface SignInButtonProps {
  /** The localized title, "Sign In". */
  label: string;
  onSignIn: () => void;
  /** md (28) next to a line of text; lg (32) on a roomy page. */
  size?: ButtonSize;
  className?: string;
  /** The app's line naming what it signs in to; none: no line. */
  backend?: string | null;
}

export function SignInButton({ label, onSignIn, size = "md", className, backend }: SignInButtonProps) {
  const button = (
    <Button variant="solid" size={size} className={className} data-action="sign-in" onClick={onSignIn}>
      {label}
    </Button>
  );
  if (!backend) return button;
  return (
    <span className="ui-sign-in">
      {button}
      <SignInBackend line={backend} />
    </span>
  );
}

/** The small secondary line under a Sign In (a page whose Sign In is not this button shows it too). */
export function SignInBackend({ line }: { line: string }) {
  return (
    <span className="ui-sign-in__backend" data-sign-in-backend="">
      {line}
    </span>
  );
}
