/** Whether sending should put the transcript at its newest row.
 *
 * Keeping this decision separate from the send transport lets every send path use the same
 * setting while preserving normal streaming follow when the reader is already at the bottom.
 */
export function shouldScrollToBottomAfterSend(scrollToBottomOnSend: boolean, atLatest: boolean): boolean {
  return scrollToBottomOnSend || atLatest;
}
