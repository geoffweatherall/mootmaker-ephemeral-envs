import { defineConfig, devices } from '@playwright/test'

// No mocking anywhere in this suite (unlike mootmaker-webapp's) - every test drives a real
// browser against a genuinely deployed webapp talking to a genuinely deployed API and real
// Cognito, so there's no local dev server to start and no baseURL we can hardcode: it changes
// per ephemeral environment. run-full-stack-tests.sh sets WEBAPP_URL from that environment's own
// Terraform output before invoking `playwright test` - see README.md.
if (!process.env.WEBAPP_URL) {
  throw new Error(
    'WEBAPP_URL is not set - this suite runs against a real deployed webapp, not a local dev ' +
      'server. Use run-full-stack-tests.sh rather than invoking `playwright test` directly.',
  )
}

export default defineConfig({
  testDir: './tests',
  // Deliberately NOT fullyParallel: every test signs up or resets a real Cognito account and
  // waits on a real email through the shared SQS queue - each test already generates its own
  // uniquely-tagged address (see tests/support/email.ts) so cross-talk isn't the concern, but
  // real infrastructure this thin a layer is meant to run rarely, not hammered concurrently.
  fullyParallel: false,
  workers: 1,
  reporter: 'list',
  // Generous timeouts: real SES/SNS/SQS delivery and real Lambda cold starts (see
  // mootmaker-webapp's own README on cold-start latency) are both meaningfully slower than
  // anything the mocked layers ever wait on.
  timeout: 120_000,
  expect: {
    timeout: 15_000,
  },
  use: {
    baseURL: process.env.WEBAPP_URL,
    trace: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], channel: 'chrome' },
    },
  ],
})
