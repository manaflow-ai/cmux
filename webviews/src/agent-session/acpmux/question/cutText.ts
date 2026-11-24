/// The parts of a shown question that are cut to their room until More: the question (two lines),
/// the line under it, and who asks and what about (the head's room).
const CUT_TEXT =
  ".acpmux-hat-questions__prompt, .acpmux-hat-questions__detail, .acpmux-hat-questions__who, .acpmux-hat-questions__about";

/// Whether any of `question`'s cut parts runs past its room.
export function hasCutText(question: HTMLElement): boolean {
  return Array.from(question.querySelectorAll<HTMLElement>(CUT_TEXT)).some(
    (part) => part.scrollHeight > part.clientHeight + 1 || part.scrollWidth > part.clientWidth + 1,
  );
}
