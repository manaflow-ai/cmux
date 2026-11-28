import { type CliConfig } from "./config.js";
export declare const DEFAULT_DASHBOARD_URL = "https://dash.freestyle.sh";
export declare function openBrowser(url: string): void;
export declare function browserLogin(options?: {
    dashboardUrl?: string;
    open?: boolean;
}): Promise<string>;
export declare function refreshAccessToken(config?: CliConfig): Promise<string>;
export declare function dashboardUrl(config?: CliConfig): string;
export declare function refreshTeams(accessToken: string, config?: CliConfig): Promise<CliConfig>;
//# sourceMappingURL=stack-auth.d.ts.map