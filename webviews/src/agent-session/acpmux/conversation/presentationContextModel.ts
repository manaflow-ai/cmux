import { createContext } from "react";
import type { Presentation } from "../chatDisplay";

export const PresentationContext = createContext<Presentation>("transcript");
