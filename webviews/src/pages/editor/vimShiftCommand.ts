// monaco-vim's one deep import (`monaco-editor/esm/vs/editor/common/commands/shiftCommand`, for `>`
// and `<`), which vite.config.ts aliases here. Monaco 0.57's ShiftCommand takes the language
// configuration service as a third argument that monaco-vim (written for 0.33) never passes; without
// it, shifting a line whose indentation is not a multiple of the indent size throws. This passes
// Monaco's own service.
import { ShiftCommand as MonacoShiftCommand } from "monaco-editor/editor/common/commands/shiftCommand.js";
import { ILanguageConfigurationService } from "monaco-editor/editor/common/languages/languageConfigurationRegistry.js";
import { StandaloneServices } from "monaco-editor/editor/standalone/browser/standaloneServices.js";

export class ShiftCommand extends MonacoShiftCommand {
  constructor(range: unknown, opts: unknown) {
    super(range, opts, StandaloneServices.get(ILanguageConfigurationService));
  }
}
