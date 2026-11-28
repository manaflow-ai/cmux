import { checkRateLimit } from '@vercel/firewall';
import { deliverDevBackendDiagnostics, makeDevBackendDiagnosticsHandler } from '../../../../services/observability/devBackendDiagnostics';

// Dev-only payloads may arrive before sign-in, including when the tag's own
// backend is unreachable. Only this server holds the ingestion credential.
export const POST = makeDevBackendDiagnosticsHandler({
  allowed: async request => {
    if (process.env.VERCEL !== '1') return true;
    const rule = process.env.CMUX_CLOUD_DIAGNOSTICS_RATE_LIMIT_ID?.trim();
    if (!rule) throw new Error('dev_diagnostics_rate_limit_unconfigured');
    const result = await checkRateLimit(rule, {request});
    if (result.rateLimited || result.error === 'blocked') return false;
    if (result.error) throw new Error('dev_diagnostics_rate_limit_unavailable');
    return true;
  },
  deliver: events => deliverDevBackendDiagnostics(events),
  now: Date.now,
});
