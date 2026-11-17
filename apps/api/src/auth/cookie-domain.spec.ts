import { getCookieDomain } from './cookie-domain';

describe('getCookieDomain', () => {
  it('uses AUTH_COOKIE_DOMAIN when set', () => {
    expect(
      getCookieDomain({
        AUTH_COOKIE_DOMAIN: '.example.com',
        BASE_URL: 'https://api.example.com',
      }),
    ).toBe('.example.com');
  });

  it('lets AUTH_COOKIE_DOMAIN win over a trycomp.ai BASE_URL', () => {
    expect(
      getCookieDomain({
        AUTH_COOKIE_DOMAIN: '.example.com',
        BASE_URL: 'https://api.trycomp.ai',
      }),
    ).toBe('.example.com');
  });

  it('ignores a blank AUTH_COOKIE_DOMAIN', () => {
    expect(
      getCookieDomain({ AUTH_COOKIE_DOMAIN: '  ', BASE_URL: 'https://api.trycomp.ai' }),
    ).toBe('.trycomp.ai');
  });

  it('returns the staging domain for staging BASE_URL', () => {
    expect(getCookieDomain({ BASE_URL: 'https://api.staging.trycomp.ai' })).toBe(
      '.staging.trycomp.ai',
    );
  });

  it('returns the production domain for trycomp.ai BASE_URL', () => {
    expect(getCookieDomain({ BASE_URL: 'https://api.trycomp.ai' })).toBe('.trycomp.ai');
  });

  it('returns undefined for other hosts without an override', () => {
    expect(getCookieDomain({ BASE_URL: 'http://localhost:3333' })).toBeUndefined();
    expect(getCookieDomain({})).toBeUndefined();
  });
});
