// Tests install the full generated string table (the shipped page loads locales/*.js instead).
import table from "./generated/strings.json";
import { installCatalog } from "./strings";

installCatalog(table as Record<string, Record<string, string>>);
