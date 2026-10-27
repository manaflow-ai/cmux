// gamma's first section: shares a with the page, b with Two and c with delta.
import { a } from "../../shared/a";
import { b } from "../../shared/b";
import { c } from "../../shared/c";

export const one = () => [a("one"), b(), c].join(" ");
