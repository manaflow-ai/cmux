import { headers } from "next/headers";
import { SignInChooser } from "./SignInChooser";
import { signInChooserMessages } from "./messages";

export const dynamic = "force-dynamic";

export default async function SignInPage() {
  const headerStore = await headers();
  const localized = await signInChooserMessages(headerStore.get("accept-language"));

  return <SignInChooser messages={localized.messages} />;
}
