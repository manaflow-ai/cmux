// gamma's second section: shares a with the page, b with One and d with delta.
import { a } from "../../shared/a";
import { b } from "../../shared/b";
import { d } from "../../shared/d";

export const two = () => [a("two"), b(), d].join(" ");
