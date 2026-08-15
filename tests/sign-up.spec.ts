import { expect, test } from '@playwright/test'
import { waitForVerificationCode } from './support/email'
import { freshTestAccount } from './support/testAccount'

// The one thing only this layer can prove: a real sign-up, through the real deployed webapp,
// against a real Cognito pool, receiving a real emailed code via the SES->SNS->SQS pipeline (see
// testing-strategy.md#reading-cognitos-emails-in-tests) and successfully confirming with it.
// mootmaker-webapp's own mocked-API suite already covers the sign-up form's UI logic (validation,
// step transitions, a fake code) - this test's only job is proving the real infrastructure behind
// it actually works end to end, so it deliberately doesn't re-check anything the mocked layer
// already does (wrong-code rejection, password-strength messaging, etc.).
test('a real sign-up receives a real emailed code and completes', async ({ page }) => {
  const account = freshTestAccount()

  await page.goto('/signup')
  await page.getByLabel('Name').fill(account.name)
  await page.getByLabel('Email').fill(account.email)
  await page.getByLabel('Password').fill(account.password)
  await page.getByRole('button', { name: 'Sign up' }).click()

  await expect(page.getByLabel('Verification code')).toBeVisible()

  const code = await waitForVerificationCode(account.email)

  await page.getByLabel('Verification code').fill(code)
  await page.getByRole('button', { name: 'Confirm' }).click()

  // Confirming signs the user in automatically and returns to "/" - "Sign out" only ever
  // appears in the nav for a signed-in session (see MenuContent.tsx).
  await expect(page.getByText('Sign out')).toBeVisible()
})
