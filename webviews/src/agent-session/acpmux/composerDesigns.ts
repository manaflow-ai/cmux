import type { ComposerDesign } from "./composerSettings";

// Layout only: the real editor, pickers and host actions never fork. Important utilities
// override the unlayered legacy composer rules; the shared pane Tailwind compiler scans this
// module for both the native bundle and gallery. Menus remain outside these selectors.
const quiet = `
  [&_.acpmux-composer-box]:bg-transparent! [&_.acpmux-composer-box]:shadow-none!
  [&_.acpmux-composer-box]:[--acpmux-composer-radius:12px]
  [&_.acpmux-composer-bar]:gap-1! [&_.acpmux-composer-bar]:text-control!
  [&_.acpmux-chips]:gap-1! [&_.acpmux-chips]:flex-wrap!
  [&_.acpmux-chips-spacer]:hidden!
  [&_.acpmux-effort]:before:hidden! [&_.acpmux-access]:before:hidden!
  [&_.acpmux-picker-button]:rounded-md! [&_.acpmux-picker-button]:text-control!
  [&_.acpmux-model-name]:text-muted! [&_.acpmux-model-name]:whitespace-normal!
  [&_.acpmux-model-name]:line-clamp-2! [&_.acpmux-model-name]:leading-tight!
  [&_.acpmux-model]:min-w-0! [&_.acpmux-model]:max-w-full!
  [&_.acpmux-picker-button]:px-1! [&_.acpmux-picker-button]:min-h-7!
  [&_.acpmux-access-trigger]:max-w-full! [&_.acpmux-mode-text]:inline!
  [&_.acpmux-access-trigger]:w-auto! [&_.acpmux-access-trigger]:gap-1!
  [&_.acpmux-context-ring]:size-7! [&_.acpmux-send]:size-7! [&_.acpmux-send]:rounded-md!
  [&_.acpmux-send:not(.acpmux-send-ready):not(.acpmux-cancel)]:bg-hover!
  [&_.acpmux-send:not(.acpmux-send-ready):not(.acpmux-cancel)]:text-dim!
  [&_.acpmux-composer-context]:border-0! [&_.acpmux-composer-context]:shadow-none!
  [&_.acpmux-composer-context]:bg-transparent! [&_.acpmux-composer-context]:h-auto!
  [&_.acpmux-composer-context]:min-h-7! [&_.acpmux-composer-context]:p-0!
  [&_.acpmux-composer-context]:flex-wrap! [&_.acpmux-composer-context]:gap-0!
  [&_.acpmux-location-leading]:flex-wrap! [&_.acpmux-location-leading]:basis-full!
  [&_.acpmux-location-label]:text-detail! [&_.acpmux-location-button]:max-w-full!
  [&_.acpmux-location-picker]:max-w-full! [&_.acpmux-location-readonly]:max-w-full!
  [&_.acpmux-md-field]:text-content! [&_.acpmux-md-field]:px-3! [&_.acpmux-md-field]:py-3!
  [&_.acpmux-md-placeholder]:left-3! [&_.acpmux-md-placeholder]:top-3!
  [&_.acpmux-md-placeholder]:right-3!
  [&_.acpmux-composer-field-menu]:min-w-0!
`;

const layouts: Record<Exclude<ComposerDesign, "today">, string> = {
  // Controls first, detached from the rounded writing capsule. Unlike a footer, the choices
  // stay on the upper edge while the draft grows downward inside its own surface.
  halo: `
    [&_.acpmux-composer-box]:gap-1!
    [&_.acpmux-composer-bar]:order-first! [&_.acpmux-composer-bar]:min-h-9!
    [&_.acpmux-composer-bar]:p-0! [&_.acpmux-composer-bar]:items-start!
    [&_.acpmux-composer-actions]:gap-1! [&_.acpmux-composer-actions]:pt-0.5!
    [&_.acpmux-composer-field-menu]:bg-menu! [&_.acpmux-composer-field-menu]:rounded-2xl!
    [&_.acpmux-composer-field-menu]:border! [&_.acpmux-composer-field-menu]:border-edge!
    [&_.acpmux-composer-context]:order-last!
  `,
  // A writing area and a narrow side rail. The picker triggers stack as text beside the
  // draft, leaving its lower edge free. The rail has no separate filled card.
  rail: `
    [&_.acpmux-composer-box]:grid! [&_.acpmux-composer-box]:grid-cols-[minmax(0,1fr)_7.5rem]!
    [&_.acpmux-composer-box]:gap-x-2! [&_.acpmux-composer-box]:gap-y-1!
    [&_.acpmux-composer-bar]:col-start-2! [&_.acpmux-composer-bar]:row-start-1!
    [&_.acpmux-composer-bar]:row-span-3! [&_.acpmux-composer-bar]:flex-col!
    [&_.acpmux-composer-bar]:items-stretch! [&_.acpmux-composer-bar]:p-0!
    [&_.acpmux-composer-bar]:ps-2! [&_.acpmux-composer-bar]:border-s!
    [&_.acpmux-composer-bar]:border-edge! [&_.acpmux-composer-bar]:justify-start!
    [&_.acpmux-chips]:flex-col! [&_.acpmux-chips]:items-start! [&_.acpmux-chips]:flex-none!
    [&_.acpmux-composer-plus]:self-start!
    [&_.acpmux-composer-actions]:m-0! [&_.acpmux-composer-actions]:gap-2!
    [&_.acpmux-composer-field-menu]:col-start-1! [&_.acpmux-composer-field-menu]:row-start-2!
    [&_.acpmux-composer-field-menu]:bg-menu! [&_.acpmux-composer-field-menu]:rounded-xl!
    [&_.acpmux-composer-field-menu]:self-start!
    [&_.acpmux-attachments]:col-start-1! [&_.acpmux-attachments]:row-start-1!
    [&_.acpmux-attachments]:m-0! [&_.acpmux-attachments]:p-0!
    [&_.acpmux-composer-context]:col-start-1! [&_.acpmux-composer-context]:row-start-3!
    [&_.acpmux-access-trigger]:h-auto! [&_.acpmux-mode-text]:whitespace-normal!
  `,
  // An editor margin: +, microphone and Send occupy a slim left gutter. Model and effort
  // head an unboxed note to its right; a single vertical hairline marks the writing edge.
  notch: `
    [&_.acpmux-composer-box]:grid! [&_.acpmux-composer-box]:grid-cols-[2rem_minmax(0,1fr)]!
    [&_.acpmux-composer-box]:gap-x-2! [&_.acpmux-composer-box]:gap-y-1!
    [&_.acpmux-composer-bar]:contents!
    [&_.acpmux-chips]:col-start-2! [&_.acpmux-chips]:row-start-1!
    [&_.acpmux-composer-plus]:col-start-1! [&_.acpmux-composer-plus]:row-start-3!
    [&_.acpmux-composer-plus]:self-start!
    [&_.acpmux-composer-actions]:col-start-1! [&_.acpmux-composer-actions]:row-start-4!
    [&_.acpmux-composer-actions]:m-0! [&_.acpmux-composer-actions]:flex-col!
    [&_.acpmux-composer-actions]:gap-1! [&_.acpmux-composer-actions]:self-start!
    [&_.acpmux-composer-field-menu]:col-start-2! [&_.acpmux-composer-field-menu]:row-start-3!
    [&_.acpmux-composer-field-menu]:border-s! [&_.acpmux-composer-field-menu]:border-edge!
    [&_.acpmux-composer-field-menu]:bg-transparent!
    [&_.acpmux-attachments]:col-start-2! [&_.acpmux-attachments]:row-start-2!
    [&_.acpmux-attachments]:m-0! [&_.acpmux-attachments]:p-0!
    [&_.acpmux-composer-context]:col-start-2! [&_.acpmux-composer-context]:row-start-4!
    [&_.acpmux-composer-context]:self-start!
  `,
};

export function composerDesignClasses(design: ComposerDesign): string {
  return design === "today" ? "" : `${quiet} ${layouts[design]}`;
}
