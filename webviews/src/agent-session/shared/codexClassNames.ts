export const CODEX_BUTTON_BASE =
  "border-token-border user-select-none no-drag cursor-interaction flex items-center gap-1 border whitespace-nowrap focus:outline-none disabled:cursor-not-allowed disabled:opacity-40";
export const CODEX_BUTTON_GHOST =
  "text-token-text-tertiary enabled:hover:bg-token-list-hover-background data-[state=open]:bg-token-list-hover-background border-transparent";
export const CODEX_BUTTON_PRIMARY =
  "bg-token-foreground enabled:hover:bg-token-foreground/80 data-[state=open]:bg-token-foreground/80 text-token-dropdown-background";
export const CODEX_BUTTON_COMPOSER = "h-token-button-composer px-2 py-0 text-sm leading-[18px]";
export const CODEX_BUTTON_COMPOSER_SM = "h-token-button-composer-sm px-1.5 py-0 text-sm leading-[18px]";
export const CODEX_BUTTON_ICON = "electron:p-1 electron:[&>svg]:icon-sm flex items-center justify-center p-0.5";
export const CODEX_BUTTON_UNIFORM = "aspect-square items-center justify-center !px-0";
export const CODEX_SUBMIT_BUTTON =
  "focus-visible:outline-token-button-background cursor-interaction size-token-button-composer flex items-center justify-center rounded-full p-0.5 transition-opacity focus-visible:outline-2 bg-token-foreground";

export const CODEX_COMPOSER_STACK = "agent-composer-stack";
export const CODEX_COMPOSER_FRAME = "codex-composer-frame relative";
export const CODEX_COMPOSER_INNER = "codex-composer-inner relative z-10 flex min-h-0 flex-1 flex-col";
export const CODEX_COMPOSER_SURFACE =
  "codex-composer-surface relative flex flex-col bg-token-input-background/90 backdrop-blur-lg extension:border extension:border-token-border/50 electron:ring electron:ring-black/10 electron:shadow-[0_4px_16px_0_rgba(0,0,0,0.05)] electron:dark:bg-token-dropdown-background";
export const CODEX_COMPOSER_FOOTER_SINGLE_LINE =
  "composer-footer grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 px-2 py-1";
export const CODEX_COMPOSER_FOOTER_MULTILINE =
  "composer-footer grid grid-cols-[minmax(0,auto)_auto_minmax(0,1fr)] items-center gap-[5px] mb-2 px-2";
