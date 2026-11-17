import { createElement } from 'react';

const mockTriggerEmail = jest.fn();
const mockSendEmail = jest.fn();

jest.mock('../email/trigger-email', () => ({
  triggerEmail: (...args: unknown[]) => mockTriggerEmail(...args),
}));
jest.mock('../email/resend', () => ({
  sendEmail: (...args: unknown[]) => mockSendEmail(...args),
}));

const email = {
  to: 'user@example.invalid',
  subject: 'One-Time Password for Comp AI',
  react: createElement('p', null, '123456'),
};

describe('sendAuthEmail', () => {
  let sendAuthEmail: typeof import('./send-auth-email').sendAuthEmail;
  let warn: jest.SpyInstance;

  beforeAll(async () => {
    ({ sendAuthEmail } = await import('./send-auth-email'));
  });

  beforeEach(() => {
    mockTriggerEmail.mockReset().mockResolvedValue({ id: 'run_1' });
    mockSendEmail.mockReset().mockResolvedValue({ id: 'email_1' });
    warn = jest.spyOn(console, 'warn').mockImplementation(() => undefined);
  });

  afterEach(() => {
    warn.mockRestore();
  });

  it('sends directly and skips the queue when AUTH_EMAIL_DIRECT=true', async () => {
    await sendAuthEmail(email, { AUTH_EMAIL_DIRECT: 'true' });

    expect(mockSendEmail).toHaveBeenCalledWith(email);
    expect(mockTriggerEmail).not.toHaveBeenCalled();
  });

  it('enqueues on Trigger.dev by default', async () => {
    await sendAuthEmail(email, {});

    expect(mockTriggerEmail).toHaveBeenCalledWith(email);
    expect(mockSendEmail).not.toHaveBeenCalled();
  });

  it('falls back to a direct send when enqueueing fails', async () => {
    mockTriggerEmail.mockRejectedValueOnce(new Error('Queue unavailable'));

    await sendAuthEmail(email, {});

    expect(mockTriggerEmail).toHaveBeenCalledTimes(1);
    expect(mockSendEmail).toHaveBeenCalledWith(email);
    expect(warn).toHaveBeenCalled();
  });

  it('throws when both the queue and the direct send fail', async () => {
    mockTriggerEmail.mockRejectedValueOnce(new Error('Queue unavailable'));
    mockSendEmail.mockRejectedValueOnce(new Error('Resend down'));

    await expect(sendAuthEmail(email, {})).rejects.toThrow('Resend down');
  });

  it('surfaces a direct-send failure in direct mode', async () => {
    mockSendEmail.mockRejectedValueOnce(new Error('Resend down'));

    await expect(
      sendAuthEmail(email, { AUTH_EMAIL_DIRECT: 'true' }),
    ).rejects.toThrow('Resend down');
    expect(mockTriggerEmail).not.toHaveBeenCalled();
  });
});
