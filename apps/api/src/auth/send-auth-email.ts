import type { ReactElement } from 'react';
import { sendEmail } from '../email/resend';
import { triggerEmail } from '../email/trigger-email';

type AuthEmail = {
  to: string;
  subject: string;
  react: ReactElement;
};

/**
 * Sends a sign-in / account email that a user is actively waiting for.
 *
 * - AUTH_EMAIL_DIRECT=true: send straight through Resend. Login then never
 *   depends on the background-job queue (and costs no task run).
 * - Otherwise: enqueue on Trigger.dev as before, but if enqueueing fails
 *   (outage, exhausted plan, misconfiguration) fall back to a direct send so
 *   users can still log in.
 */
export async function sendAuthEmail(
  params: AuthEmail,
  env: Partial<NodeJS.ProcessEnv> = process.env,
): Promise<void> {
  if (env.AUTH_EMAIL_DIRECT === 'true') {
    await sendEmail(params);
    return;
  }

  try {
    await triggerEmail(params);
  } catch (error) {
    console.warn('[Auth] Email queue unavailable; sending directly via Resend', {
      subject: params.subject,
      error: error instanceof Error ? error.message : String(error),
    });
    await sendEmail(params);
  }
}
