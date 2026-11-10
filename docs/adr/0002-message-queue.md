# ADR-0002: Message queue

- Status: Accepted
- Date: 2026-11-09

## Context

Publishing must return quickly (p99 < 100 ms), so delivery can't happen inside the API request. After an event is stored, each of its deliveries (one per subscribed endpoint) is handed to a queue, and workers read from the queue and call the webhooks.

The queue must:

- Keep messages if a worker crashes, and hand them to another worker.
- Run locally for development and tests.

## Options considered

- **Amazon SQS:** managed, at-least-once, with visibility timeouts. Runs locally on LocalStack.
- **Redis with BullMQ:** built-in delayed jobs and retries, but Redis is one more system to run and its persistence needs tuning so jobs aren't lost.
- **Postgres-backed queue:** no extra system, and the event and its queue entry are written in one transaction, so there is no dual write. But workers poll the database, which adds load as volume grows.

## Decision

We use Amazon SQS (standard queue) as the message queue, with LocalStack for local development. It is widely used and well supported, the service is meant to run on AWS, and I am already familiar with it.

- Messages carry only the delivery ID. The payload stays in Postgres, so message size never depends on the event's size.
- The DLQ from ADR-0001 is a delivery status in Postgres, so tenants can query and retry it. SQS's own dead-letter queue (redrive policy) only catches messages that crash workers repeatedly.
- Retries are scheduled in Postgres, not in SQS. Each delivery stores `next_attempt_at`, and a scheduler enqueues deliveries when they are due, so SQS only holds deliveries that are ready to send now. Each attempt is a new SQS message, which keeps the receive count meaningful for the redrive policy.
- The outbox job and the retry scheduler can run as several instances. Each instance claims a batch of rows with `SELECT ... FOR UPDATE SKIP LOCKED`, sends them to SQS, marks them `queued` and commits, so two instances never take the same rows and there is no global lock. If an instance crashes after sending but before committing, the locks are released and the rows are sent again, which at-least-once allows. Batches stay small so the transaction is short.

## Consequences

- SQS standard queues are at-least-once with no ordering guarantee. This matches our [delivery guarantee](../design.md#delivery-guarantee), so we don't need a FIFO queue.
- Deliveries are stored in Postgres and sent to SQS in two separate steps. An outbox job re-sends deliveries stuck in `saved` (see the edge cases in [design.md](../design.md)).
- Our retry delays reach ~9.6 h, but SQS's per-message delay is capped at 15 minutes. Holding retries in flight with the visibility timeout would not work either: a standard queue allows about 120,000 in-flight messages, so one dead endpoint with a large backlog could block the whole queue for every tenant. Hence the Postgres scheduler.
- The scheduler polls Postgres for due deliveries, which adds some database load.
- If a worker crashes, the message reappears after the visibility timeout and another worker retries it. The visibility timeout must be longer than the 10 s request timeout.
- LocalStack doesn't match AWS in every detail, so the main flows also need testing against real SQS before production.
