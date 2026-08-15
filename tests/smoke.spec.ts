import { expect, test } from '@playwright/test'

// Proves the cross-service serving path nothing else in this project's test suites can see: DNS
// resolution for this ephemeral environment's hostname, a valid TLS certificate, and CloudFront
// actually serving the built webapp out of S3 - not auth, not the API, not any business logic
// (all of that is covered elsewhere, see testing-strategy.md).
test('the deployed webapp serves its real home page', async ({ page }) => {
  const response = await page.goto('/')

  expect(response?.ok()).toBe(true)
  await expect(page).toHaveTitle('Mootmaker')
  await expect(page.getByRole('heading', { name: 'Welcome to Mootmaker' })).toBeVisible()
})
