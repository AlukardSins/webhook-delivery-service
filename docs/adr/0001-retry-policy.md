# ADR-0001: Retry policy

- Status: Accepted
- Date: 2026-11-09

## Context

We promise at-least-once delivery (see [Delivery guarantee](../design.md#delivery-guarantee)), so a failed delivery must be tried again. Receivers fail for many reasons: a deploy that takes a few minutes, an outage that lasts hours, a firewall rule, an expired certificate. From our side, we only see a status code, a timeout or a connection error, and we usually can't tell whether the failure is temporary or permanent.

The retry policy has to balance three things:

- **Give receivers time to recover.** A short window turns a routine deploy into lost events.
- **Don't overload a receiver that is recovering.** Retries that all arrive at once can take it down again.
- **Stop eventually.** Deliveries that can never succeed must end somewhere the tenant can see them and act.

This ADR decides which responses are retried, on what schedule, and what happens when retries run out.

## Options considered

- **Short retry window (seconds), like SDK retries:** simple, but a receiver that is down for a few minutes loses events to the DLQ.
- **Long window, retrying only selected codes:** avoids retrying "permanent" errors, but many 4xx errors are temporary in practice, so one bad deploy on the receiver's side sends events straight to the DLQ.
- **Long window, retrying every failure except 410 Gone:** one simple rule. It costs more attempts against dead endpoints, but the long window and the backoff keep that load low. This is what Stripe and Svix do.

## Decision

We retry every failure except 410 Gone, over a window of at least 32 hours, with exponential backoff and jitter.

### Which responses are retried

Every non-2xx response is retried, as are timeouts and connection errors. Many 4xx errors are temporary: a 404 during a receiver's deploy, or a 401 or 403 from a firewall or a secret mid-rotation.

- **3xx:** redirects are not followed, so a 3xx counts as a failed attempt and is retried. The attempt history stores the `Location` header so the tenant can fix the URL.
- **429:** retried, but the next attempt waits for the longer of the `Retry-After` value and the scheduled delay, up to the 8 h cap.
- **410:** not retried. The endpoint is deactivated (soft delete) and the tenant is notified.

### Schedule

- Retries: 15 (16 delivery attempts in total)
- Base delay: 15 s
- Backoff multiplier: 2x
- Max backoff cap: 8 h
- Jitter: each delay is multiplied by a random factor between 0.8 and 1.2

Formula, with `attempt` starting at 1 for the first retry:

$$Delay = \min(Base \times 2^{(attempt-1)},\ Cap) \times random(0.8,\ 1.2)$$

Jitter spreads retries out, so when a failing endpoint recovers, all of its pending retries don't hit it at the same moment.

Resulting schedule, before jitter:

| Retry | Delay | Total time since first attempt |
| --- | --- | --- |
| 1 | 15 s | 15 s |
| 2 | 30 s | 45 s |
| 3 | 1 min | ~2 min |
| 4 | 2 min | ~4 min |
| 5 | 4 min | ~8 min |
| 6 | 8 min | ~16 min |
| 7 | 16 min | ~32 min |
| 8 | 32 min | ~1 h 04 min |
| 9 | ~1 h 04 min | ~2 h 08 min |
| 10 | ~2 h 08 min | ~4 h 16 min |
| 11 | ~4 h 16 min | ~8 h 32 min |
| 12 | 8 h (cap) | ~16 h 32 min |
| 13 | 8 h (cap) | ~24 h 32 min |
| 14 | 8 h (cap) | ~32 h 32 min |
| 15 | 8 h (cap) | ~40 h 32 min |

An endpoint has at least 32 hours to recover before the delivery moves to the DLQ (~40.5 h without jitter, ~32.5 h in the worst case, when every delay is ×0.8).

### When retries run out

- While retries are pending, the tenant can trigger a manual retry. It replaces the next scheduled attempt: it sets the delivery's `next_attempt_at` to now, so the scheduler sends it through the same path, counts it as that attempt, and schedules the following one from it. The manual and the scheduled attempt never both go out.
- If the last retry fails, the delivery is marked as failed and moved to the DLQ, and the tenant is notified.
- The endpoint is deactivated only if it had no successful delivery during that delivery's retry window. A receiver that rejects one payload but accepts others stays active.
- When an endpoint is deactivated, its other pending deliveries are paused. The tenant re-enables the endpoint through the API; paused deliveries then resume, and deliveries in the DLQ can be retried manually.

### Sources

We chose a long retry window following these webhook best practices:

- <https://hookdeck.com/docs/outpost/guides/outbound-webhook-retry-best-practices>
- <https://www.svix.com/resources/webhook-best-practices/retries/>
- <https://wpwebhooks.org/blog/webhook-retry-policy-exponential-backoff/>

## Consequences

- Retries cover up to ~40 hours of a webhook endpoint being down. During that time, its events can be delivered with a long delay.
- Retries 12 to 15 wait between 6 h 24 min and 9 h 36 min (the 8 h cap ×0.8 to ×1.2). When an endpoint recovers, its pending events can take up to ~9.5 h to be delivered unless they are retried manually.
- Retries can deliver an event the receiver already processed, so receivers must deduplicate by event ID.
- Each delivery can produce up to 16 attempt rows, which adds to the history that [ADR-0003](0003-retention.md) has to manage.
- Delays reach ~9.6 h, longer than SQS can hold, so retries are scheduled in Postgres (see [ADR-0002](0002-message-queue.md)).
