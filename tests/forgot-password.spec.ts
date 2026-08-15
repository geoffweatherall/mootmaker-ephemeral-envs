import { expect, test } from '@playwright/test'
import { createConfirmedTestAccount } from './support/cognitoAdmin'
import { waitForVerificationCode } from './support/email'
import { freshTestAccount } from './support/testAccount'

// Same reasoning as sign-up.spec.ts: the only thing this test needs to prove is that a real
// reset code, requested through the real deployed webapp, actually arrives via the real
// SES->SNS->SQS pipeline and is accepted. The account this resets is created directly via the
// Cognito Admin API (see cognitoAdmin.ts) rather than through the sign-up UI - that's sign-up's
// own test's job, not this one's; this test's real UI interaction should only be the
// forgot-password flow it's actually testing.
test('a real password reset receives a real emailed code and completes', async ({ page }) => {
  const account = freshTestAccount()
  await createConfirmedTestAccount(account)

  await page.goto('/forgot-password')
  await page.getByLabel('Email').fill(account.email)
  await page.getByRole('button', { name: 'Send code' }).click()

  await expect(page.getByLabel('Verification code')).toBeVisible()

  const code = await waitForVerificationCode(account.email)
  const newPassword = `${account.password}-reset`

  await page.getByLabel('Verification code').fill(code)
  await page.getByLabel('New password').fill(newPassword)
  await page.getByRole('button', { name: 'Reset password' }).click()

  // Resetting signs the user in automatically and returns to "/" - same signed-in check as
  // sign-up.spec.ts.
  await expect(page.getByText('Sign out')).toBeVisible()
})
