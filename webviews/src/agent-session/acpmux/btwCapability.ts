/** The daemon capability required for the inline /btw reply shape. */
export const BTW_INLINE = "btw-inline-v1";

export function supportsBtwInline(capabilities: ReadonlySet<string> | undefined): boolean {
  return capabilities?.has(BTW_INLINE) === true;
}
