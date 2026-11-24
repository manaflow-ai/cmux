import { translate } from "../i18n";

/// New Project on a Mac whose cmux can't make projects: the one refusal the notice words itself.
export class NewProjectUnsupported extends Error {
  constructor() {
    super(translate("project.new.unavailable"));
  }
}
