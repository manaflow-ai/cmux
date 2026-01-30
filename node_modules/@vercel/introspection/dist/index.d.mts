//#region src/index.d.ts
declare const introspectApp: (args: {
  dir: string;
  handler: string;
  framework: string | null | undefined;
  env: Record<string, string | undefined>;
}) => Promise<{
  routes: ({
    handle: string;
    src?: undefined;
    dest?: undefined;
  } | {
    src: string;
    dest: string;
    handle?: undefined;
  })[];
  framework: {
    slug: string;
    version: string;
  };
} | {
  routes: ({
    src: string;
    dest: string;
    methods: string[];
  } | {
    handle: string;
    src?: undefined;
    dest?: undefined;
  } | {
    src: string;
    dest: string;
    handle?: undefined;
  })[];
  framework: {
    slug: string;
    version: string;
  };
  additionalFolders: string[];
  additionalDeps: string[];
}>;
//#endregion
export { introspectApp };