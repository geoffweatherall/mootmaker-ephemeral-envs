import {
  AdminConfirmSignUpCommand,
  AdminUpdateUserAttributesCommand,
  CognitoIdentityProviderClient,
  SignUpCommand,
} from '@aws-sdk/client-cognito-identity-provider'
import { discardAnyPendingMessages } from './email'
import type { TestAccount } from './testAccount'

// Uses the caller's own AWS credentials (the same SSO session used for everything else in this
// project - see mootmaker-bootstrap-aws-accounts), not a Lambda execution role: this runs on the
// machine driving the test suite, not inside AWS.
const cognitoClient = new CognitoIdentityProviderClient({})

function requireEnv(name: string): string {
  const value = process.env[name]
  if (!value) {
    throw new Error(`${name} is not set - see run-full-stack-tests.sh.`)
  }
  return value
}

/**
 * Creates a confirmed, working test account WITHOUT going through the real code-entry UI -
 * `AdminConfirmSignUp` confirms a sign-up with no code at all (see
 * mootmaker/testing-strategy.md#reading-cognitos-emails-in-tests's "Bypassing the code
 * requirement entirely"). Use this for anything that needs a working signed-up account as a
 * *precondition* rather than as the thing actually under test - e.g. forgot-password.spec.ts
 * needs an existing account before it can test resetting that account's password; it is not
 * itself testing that sign-up works (sign-up.spec.ts already covers that, through the real UI
 * with a real emailed code).
 *
 * Still a completely real Cognito account in the deployed pool - AdminConfirmSignUp fires the
 * same PostConfirmation trigger a real code-confirmed sign-up would (creating the linked Person,
 * setting the default class), so anything reading the account back (e.g. signing in through the
 * real UI afterward) sees a normal, fully-set-up account.
 */
export async function createConfirmedTestAccount(account: TestAccount): Promise<void> {
  const clientId = requireEnv('COGNITO_WEBAPP_CLIENT_ID')
  const userPoolId = requireEnv('COGNITO_USER_POOL_ID')

  // No explicit "email" attribute: the pool's username_attributes is ["email"], so Username
  // above already establishes it - passing it again was rejected empirically
  // (NotAuthorizedException: "A client attempted to write unauthorized attribute") even though
  // it's harmless in the real webapp's own signUp() (auth/cognito.ts), which goes through
  // amazon-cognito-identity-js rather than this SDK's SignUpCommand directly.
  await cognitoClient.send(
    new SignUpCommand({
      ClientId: clientId,
      Username: account.email,
      Password: account.password,
      UserAttributes: [{ Name: 'name', Value: account.name }],
    }),
  )

  await cognitoClient.send(
    new AdminConfirmSignUpCommand({
      UserPoolId: userPoolId,
      Username: account.email,
    }),
  )

  // A code-confirmed sign-up auto-verifies the email that received it (auto_verified_attributes
  // in cognito.tf); AdminConfirmSignUp bypasses that same code, so it isn't implied to also prove
  // ownership of the address the way it normally would. Set explicitly rather than assume, since
  // the pool's account_recovery_setting is "verified_email" - forgot-password.spec.ts needs this
  // true or requesting a reset code has no verified contact method to send it to.
  await cognitoClient.send(
    new AdminUpdateUserAttributesCommand({
      UserPoolId: userPoolId,
      Username: account.email,
      UserAttributes: [{ Name: 'email_verified', Value: 'true' }],
    }),
  )

  // SignUpCommand above triggers Cognito to send its own sign-up confirmation-code email as a
  // side effect, even though AdminConfirmSignUp bypasses needing that code - left in the shared
  // queue, a later waitForVerificationCode call for this same address (e.g. a subsequent
  // forgot-password request) could pick up this unrelated, unusable code instead of the real one,
  // since the queue is a standard (unordered) SQS queue. Drain it now, before the caller does
  // anything that requests a real code.
  await discardAnyPendingMessages(account.email)
}
