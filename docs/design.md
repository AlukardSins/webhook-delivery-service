# webhook-delivery-service

- Status: Draft
- Date: 2026-11-09

## Problem

We need a multi-tenant service that lets tenants notify their other systems when events occur.
Tenants publish events through an API, and the service delivers them to the subscribed webhook endpoints. Delivery has to keep working when:

- Our service is down, or the webhook endpoint is unreachable.
- The producer retries the same publish several times within a short interval.
- A request times out on either end.

Calling webhooks inline from the API would lose events or slow down publishing in all of these cases.

## Functional

- Tenants can register webhook endpoints with a URL; the service generates a signing secret for each one.
- Tenants can create event types and link them to endpoints through subscriptions.
- Tenants can publish events of a registered event type.
- Tenants can check the status and attempt history of an event's deliveries. Each (event, endpoint) pair is one delivery with its own status, so one endpoint can succeed while another fails.
- Events are delivered at least once.
- Failed deliveries are retried with backoff and moved to a DLQ when retries run out.
- Publish accepts an idempotency key, scoped per tenant; repeating a key within 24 h returns the original event. Keys are deleted after 24 h by their own cleanup job, separate from event retention.
- Each delivery includes a stable event ID header so receivers can deduplicate.
- Each delivery is signed with HMAC-SHA256 over the timestamp and body, using the endpoint's secret. Every attempt, including retries, is signed with a fresh timestamp, so a late retry still passes the receiver's 5-minute check.
- Signing secrets are encrypted at rest with AES-256-GCM in the application, using a key from an environment variable locally or from KMS when deployed. They can't be hashed like API keys, because signing needs the plaintext, and a database dump must not expose them.
- Every API endpoint requires authentication and per-tenant authorization.
- All requests are validated.
- Requests are rate limited per tenant, and the API returns 429 above the limit. Each tenant has its own publish limit, stored on the tenant, with a default of 2000 events per second. The default is set above the 1000-per-second promotion threshold in [ADR-0004](adr/0004-tenant-fairness.md), so a growing tenant triggers a review before it hits the limit; a tenant's limit is raised or lowered case by case during the same review. In v1 the limiter is in memory: each API instance enforces the tenant's limit divided by the number of instances. This is approximate (uneven load across instances lets a tenant go a little over or under its limit), but it needs no shared state; a shared store such as Redis would only be added if exact limits become necessary.

## Delivery guarantee

We promise **at-least-once** delivery. Every event is retried until the receiver returns a 2xx or the retries run out (see [ADR-0001: Retry policy](adr/0001-retry-policy.md)).

Exactly-once delivery over HTTP isn't achievable. When a request times out, we can't tell whether the receiver never got it or got it and the response was lost, so we send it again.

We don't promise ordering or the absence of duplicates. A retry of event 1 can arrive after event 2, and the same event can arrive more than once.

Receivers must:

- Deduplicate by the event ID header, which stays the same across retries: store the IDs already processed and ignore repeats.
- Tolerate out-of-order delivery, for example by comparing the event's timestamp with the state they already have.
- Verify the signature of every delivery before processing it, and reject deliveries whose signed timestamp is more than 5 minutes old.

## Delivery lifecycle

Each delivery has one status. These are the only statuses and the only allowed transitions.

| Status | Meaning |
| --- | --- |
| `saved` | Stored at publish, not yet sent to SQS. |
| `queued` | Sent to SQS, waiting for a worker. |
| `scheduled` | Waiting for its next retry at `next_attempt_at`. |
| `delivered` | The receiver returned a 2xx. Final. |
| `failed` | Retries ran out, or the receiver returned 410. This is the DLQ. |
| `paused` | Its endpoint is deactivated. |
| `cancelled` | Its endpoint was deleted. Final. |

| From | To | Who | When |
| --- | --- | --- | --- |
| (new) | `saved` | API | Publish, in the same transaction as the event. |
| `saved` | `queued` | API, outbox job | Sent to SQS at publish, or re-sent by the outbox job or a republish with the same idempotency key. |
| `scheduled` | `queued` | Scheduler | `next_attempt_at` is due. A manual retry sets it to now. |
| `queued` | `delivered` | Worker | The receiver returned a 2xx. |
| `paused` | `delivered` | Worker | The receiver returned a 2xx for a call that started before the endpoint was deactivated. |
| `queued` | `scheduled` | Worker | The attempt failed and retries are left, or the endpoint's delivery cap was reached (no attempt is counted). |
| `queued` | `failed` | Worker | The last retry failed, or the receiver returned 410. |
| `failed` | `scheduled` | Tenant | Manual retry from the DLQ, with `next_attempt_at` set to now. |
| `saved`, `queued`, `scheduled` | `paused` | Tenant, worker | The endpoint is deactivated by the tenant or by [ADR-0001](adr/0001-retry-policy.md). |
| `paused` | `scheduled` | Tenant | The endpoint is re-enabled, with `next_attempt_at` set to now. |
| `saved`, `queued`, `scheduled`, `paused`, `failed` | `cancelled` | Tenant | The endpoint is deleted. |

Rules:

- A manual retry from the DLQ is a single extra attempt. It doesn't reset the attempt count or start a new retry window; if it fails, the delivery goes back to `failed`.
- A worker loads the delivery before sending and skips it unless its status is `queued`. This drops messages for deliveries that were paused, cancelled or already delivered while still in SQS.
- A worker records the result with a conditional update (`WHERE id = ? AND status = 'queued'`), so when two workers hold the same SQS duplicate, only one records an outcome. A 2xx matches `status IN ('queued', 'paused')` instead, because a delivery that arrived is always recorded as `delivered`, even if its endpoint was deactivated mid-call. A cancelled delivery stays `cancelled`; its attempt row still records the 2xx.

## API authentication

- Each tenant has one or more API keys, sent as a Bearer token.
- A key is shown once, at creation. We store only its SHA-256 hash, plus a short visible prefix used to find the key and to show it in listings. The hashes are compared with `crypto.timingSafeEqual`.
- Keys can be revoked, and they never appear in logs.
- Every request is authorized against the tenant that owns the key, so a tenant can only access its own resources.

## Non-functional

- Publish returns 202 after the event is stored in the database (Postgres), with p99 < 100 ms.
- Time from publish to the first delivery attempt is p99 < 5 s.
- Event history is kept for 6 months in Postgres, then archived for another 6 months (1 year in total). See [ADR-0003: Retention](adr/0003-retention.md).
- Delivery capacity is shared by volume, not split evenly. Each tenant has a reserved minimum, and tenants that send more can use the spare capacity above it. When tenants compete for spare capacity, we review case by case whether a tenant should get more resources than the others, using the per-tenant metrics below. See [ADR-0004: Tenant fairness](adr/0004-tenant-fairness.md).
- Metrics are tracked per tenant: publish latency, delivery success rate, attempts per delivery, queue depth and DLQ size. An alert fires when queue depth or DLQ size keeps growing.

## Non-goals

- No dashboard.
- No support for multiple databases.
- No support for multiple message brokers; we use Amazon SQS (the official AWS emulator for local development). See [ADR-0002: Message queue](adr/0002-message-queue.md) and [ADR-0005: Local SQS emulator](adr/0005-local-sqs-emulator.md).
- No ordering guarantee.
- No payload transformations.
- Input only through the API; no inbound webhooks.
- No changes to events after they are stored.

## v1 scope

The design covers more than v1 builds. v1 runs locally only (Postgres and the AWS emulator for SQS).

Built in v1:

- Everything in [Functional](#functional), the [Delivery guarantee](#delivery-guarantee) and [API authentication](#api-authentication).
- Retries and the DLQ from [ADR-0001](adr/0001-retry-policy.md), scheduled in Postgres as in [ADR-0002](adr/0002-message-queue.md).
- One shared SQS standard queue for every tenant.

Designed, not built:

- [ADR-0004: Tenant fairness](adr/0004-tenant-fairness.md): no dedicated queues, promotion or reserved capacity. In v1, the per-tenant rate limit is the only protection against a noisy tenant. Fairness can only be tested on real SQS.
- [ADR-0003: Retention](adr/0003-retention.md): no S3 archive, cleanup job or export API. v1 keeps all history in Postgres.

## Edge cases

- An event is stored in the database but fails to enqueue. -> The event and its deliveries are stored in one transaction. Each delivery starts with status `saved` and moves to `queued` once it is sent to SQS, so with 3 endpoints, if only the second fails to enqueue, only that delivery stays `saved`. An outbox job re-sends deliveries that stay in `saved` for more than 30 s, and a republish with the same idempotency key re-queues the event's stuck deliveries immediately. Either path can enqueue a delivery twice; receivers deduplicate by event ID.
- Same idempotency key but different payload. -> 422, Key already used with a different payload.
- Concurrent publishes with the same key -> The key and the event are inserted in one transaction. The unique constraint on (tenant_id, idempotency_key) makes the second insert wait until the first commits; it then sees the conflict and returns the original event, or 422 if the payload differs.
- An event's type has no subscriptions. -> Stored, not delivered.
- An event's type is not registered. -> 422.
- A tenant uses another tenant's event type. -> 404, so the type's existence isn't revealed.
- The webhook responds with a 4xx or 5xx. -> See [ADR-0001: Retry policy](adr/0001-retry-policy.md).
- The webhook takes longer than the timeout (10 s). -> Treated as a 5xx and retried.
- Our service is down for an extended time (> 1 day). -> Publish fails with no 202, so nothing is stored. Our guarantee starts at the 202: producers must retry on 5xx or timeout, using the same idempotency key.
- A subscribed webhook endpoint is no longer reachable. -> Retried up to the limit, then moved to the DLQ. See [ADR-0001: Retry policy](adr/0001-retry-policy.md).
- A tenant checks event history older than 6 months. -> See [ADR-0003: Retention](adr/0003-retention.md).
- The webhook received the request and returned 200, but we crashed before recording it. -> Resent; the receiver deduplicates using the event ID header.
- A noisy tenant publishes 1M events. -> Rate limited with 429.
- A tenant uses the service as a DDoS amplifier, pointing an endpoint at a public third-party URL and publishing at its full rate limit. -> Each endpoint has a delivery cap, by default 100 deliveries per second, enforced in memory like the API rate limiter: each worker allows the cap divided by the number of workers, so the total stays at the cap. Deliveries over the cap are rescheduled without counting an attempt. The cap is raised per endpoint during the same review as the tenant's rate limit. Endpoint verification (a challenge the receiver must answer before deliveries start) is left for after v1.
- SSRF: a tenant registers <http://localhost> or <http://169.254.169.254> (the cloud metadata address) as an endpoint. -> Checked at registration and before every delivery attempt; redirects are not followed.
  - DNS is resolved once per attempt, the IP is checked, and the connection goes to that same IP, so DNS rebinding can't swap in a private address.
  - Blocked ranges: private, loopback, link-local and unspecified addresses for IPv4 and IPv6 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `127.0.0.0/8`, `169.254.0.0/16`, `0.0.0.0`, `::1`, `fc00::/7`, `fe80::/10`, `::`), including IPv4-mapped IPv6 (`::ffff:127.0.0.1`).
  - IPs written in decimal, octal or hex (`http://2130706433`) are parsed into their standard form before the check.
- Subscriptions change between publish and delivery. -> Subscriptions are snapshotted at publish: one delivery is created per subscribed endpoint, and later changes only affect new events.
- An endpoint is deleted or deactivated while deliveries are pending. -> Deleted: pending deliveries are marked `cancelled`. Deactivated: they are paused and resume when the tenant re-enables the endpoint.
- A worker crashes mid-delivery, and the SQS visibility timeout lets another worker send it again. -> Allowed under at-least-once. Attempts are append-only rows, so a crashed attempt stays in the history with an unknown result. The visibility timeout is longer than the 10 s request timeout.
- The payload is very large. -> 413 above 1 MB.
- An attacker captures a signed delivery and replays it later. -> Each delivery has a timestamp header that is part of the signed content. Receivers reject deliveries whose timestamp is more than 5 minutes old.
- An endpoint's secret is rotated while retries are pending. -> Every attempt is signed with the secret that is current at send time. After a rotation, the old secret stays valid for 24 h, and deliveries carry both signatures during that overlap.
- The retry of event 1 arrives after event 2. -> Not prevented; receivers handle it as described in [Delivery guarantee](#delivery-guarantee).
- The receiver sends back a huge or slow response body. -> We read at most 64 KB of the body and store only that. The 10 s timeout covers the whole request, including reading the body, so a slow receiver can't hold a worker.
