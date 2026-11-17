/**
 * Determine the session cookie domain.
 *
 * AUTH_COOKIE_DOMAIN (e.g. ".example.com") lets self-hosted deployments share
 * the session cookie across their app/portal/api subdomains. Without it the
 * cookie is host-only on the API domain and the app's proxy never sees it.
 */
export function getCookieDomain(
  env: Partial<NodeJS.ProcessEnv> = process.env,
): string | undefined {
  const override = env.AUTH_COOKIE_DOMAIN?.trim();
  if (override) {
    return override;
  }

  const baseUrl = env.BASE_URL || '';

  if (baseUrl.includes('staging.trycomp.ai')) {
    return '.staging.trycomp.ai';
  }
  if (baseUrl.includes('trycomp.ai')) {
    return '.trycomp.ai';
  }
  return undefined;
}
