import { createContext } from "react";

/// Pane actions available to a render, with sends and links confirmed in the pane first.
export const RenderBridgeContext = createContext<
  | {
      prefill(text: string): void;
      send(text: string): boolean | void | Promise<unknown>;
      openLink(url: string): void;
    }
  | undefined
>(undefined);
