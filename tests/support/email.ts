import { DeleteMessageCommand, ReceiveMessageCommand, SQSClient } from '@aws-sdk/client-sqs'
import { randomUUID } from 'node:crypto'
import { simpleParser } from 'mailparser'

const MAIL_DOMAIN = 'mail.mootmaker.com'

// Shared, persistent pipeline (see testing-strategy.md - one SQS queue, not one per environment
// or per test), so concurrent runs/tests distinguish their own mail purely by address, not by
// infrastructure. Every test that needs a real emailed code should call this once and use the
// result as the account's email - never reuse an address across tests, or a slow/retried
// long-poll could pick up another test's message.
export function uniqueTestEmail(): string {
  return `e2e-${randomUUID()}@${MAIL_DOMAIN}`
}

const sqsClient = new SQSClient({})

function queueUrl(): string {
  const url = process.env.SQS_QUEUE_URL
  if (!url) {
    throw new Error('SQS_QUEUE_URL is not set - see run-full-stack-tests.sh.')
  }
  return url
}

/**
 * Long-polls the shared inbound-mail queue until a message addressed to `email` arrives, then
 * extracts the verification code from its body and deletes the message (so it isn't left for a
 * later, unrelated poll to stumble over - see the queue's 14-day retention in sqs.tf, which
 * exists for debugging a stuck run, not as a reason to leave consumed messages lying around).
 *
 * Cognito's default verification email is short, plain-text-or-simple-HTML, multipart MIME -
 * `mailparser` handles the actual MIME/transfer-encoding decoding (quoted-printable, base64,
 * etc.) rather than this function guessing at it by regexing the raw SES notification body,
 * which would be fragile the moment the message isn't already plain ASCII.
 *
 * Any message addressed to someone else is left on the queue untouched (not deleted, not
 * consumed) precisely because another concurrent test may be waiting on it.
 */
export async function waitForVerificationCode(email: string, timeoutMs = 60_000): Promise<string> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const { Messages } = await sqsClient.send(
      new ReceiveMessageCommand({
        QueueUrl: queueUrl(),
        MaxNumberOfMessages: 10,
        // Long poll - avoids a tight empty-queue loop while still returning immediately once
        // SES/SNS actually deliver something.
        WaitTimeSeconds: 10,
      }),
    )

    for (const message of Messages ?? []) {
      const code = await tryExtractCodeForRecipient(message.Body ?? '', email)
      if (code) {
        if (message.ReceiptHandle) {
          await sqsClient.send(new DeleteMessageCommand({ QueueUrl: queueUrl(), ReceiptHandle: message.ReceiptHandle }))
        }
        return code
      }
    }
  }

  throw new Error(`Timed out after ${timeoutMs}ms waiting for a verification code addressed to ${email}`)
}

/**
 * Consumes and discards any message(s) already addressed to `email`, without requiring one to
 * exist - a short, best-effort drain, not a wait. `SignUpCommand` triggers Cognito to send its own
 * sign-up confirmation-code email as a side effect even when the caller immediately bypasses that
 * code via AdminConfirmSignUp (see cognitoAdmin.ts's createConfirmedTestAccount) - left alone, that
 * straggler email sits in this shared, standard (unordered) SQS queue and can be picked up by a
 * *later* waitForVerificationCode call for an unrelated real code request to the same address,
 * since standard queues don't guarantee delivery order. Call this right after any account-creation
 * path that has this side effect, before the real code-under-test is requested, so the queue is
 * known-empty for that address by the time the real wait begins.
 */
export async function discardAnyPendingMessages(email: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const { Messages } = await sqsClient.send(
      new ReceiveMessageCommand({ QueueUrl: queueUrl(), MaxNumberOfMessages: 10, WaitTimeSeconds: 3 }),
    )
    if (!Messages || Messages.length === 0) {
      return
    }

    for (const message of Messages) {
      let notification: { mail?: { destination?: string[] }; receipt?: { recipients?: string[] } }
      try {
        notification = JSON.parse(message.Body ?? '')
      } catch {
        continue
      }
      const recipients = notification.mail?.destination ?? notification.receipt?.recipients ?? []
      if (recipients.some((recipient) => recipient.toLowerCase() === email.toLowerCase()) && message.ReceiptHandle) {
        await sqsClient.send(new DeleteMessageCommand({ QueueUrl: queueUrl(), ReceiptHandle: message.ReceiptHandle }))
      }
    }
  }
}

/**
 * Returns the code if this message is addressed to `email` and a code could be found in it;
 * returns null otherwise (wrong recipient, or a real message that unexpectedly had no code -
 * either way, the caller must not delete it, so leaving message-shape assumptions loose here and
 * just returning null is the safe default).
 */
async function tryExtractCodeForRecipient(rawBody: string, email: string): Promise<string | null> {
  let notification: { mail?: { destination?: string[] }; content?: string; receipt?: { recipients?: string[] } }
  try {
    notification = JSON.parse(rawBody)
  } catch {
    return null
  }

  const recipients = notification.mail?.destination ?? notification.receipt?.recipients ?? []
  if (!recipients.some((recipient) => recipient.toLowerCase() === email.toLowerCase())) {
    return null
  }

  const rawMime = notification.content
  if (!rawMime) {
    return null
  }

  const parsed = await simpleParser(rawMime)
  // mailparser types html as `string | false` (false = no HTML part) rather than undefined, so
  // it doesn't chain through `??` the way text's `string | undefined` does.
  const bodyText = parsed.text || parsed.html || ''
  // Cognito's default template reads "Your verification code is 123456" (sign-up) / similar
  // wording for a reset code - looking for any standalone 6-digit run is deliberately loose about
  // the surrounding wording (which isn't part of this project's contract, just Cognito's default
  // copy) rather than brittle about exact phrasing.
  const match = bodyText.match(/\b(\d{6})\b/)
  return match ? match[1] : null
}
