import type { ComponentProps } from "react";
import { inputCommandProps } from "./inputCommandProps";

/** A native field with the shared Return, Escape and composition behavior. */
export function CommandInput({
  commands,
  ...props
}: ComponentProps<"input"> & { commands: Parameters<typeof inputCommandProps>[0] }) {
  return <input {...props} {...inputCommandProps(commands)} />;
}
