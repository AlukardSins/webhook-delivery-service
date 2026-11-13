# ADR-0005: Local SQS emulator

- Status: Accepted
- Date: 2026-11-13
- Supersedes: the local development part of [ADR-0002](0002-message-queue.md) (LocalStack). The choice of SQS itself still stands.

## Context

[ADR-0002](0002-message-queue.md) chose Amazon SQS, with LocalStack for local development and tests. LocalStack now requires an account to run, which adds sign-up, a token to manage, and a token for CI, all for a public portfolio project that should run with `docker compose up` alone.

We need a different way to run SQS locally. The emulator has to behave like real SQS in the parts this service relies on:

- Standard queue: send, receive, delete, batch calls.
- Visibility timeout and `ChangeMessageVisibility` (worker crash means redelivery).
- `ApproximateReceiveCount` and the redrive policy to the SQS dead-letter queue (ADR-0002).
- Long polling.
- No duplicate delivery to concurrent receivers while a message is in flight.

## Options considered

- **LocalStack:** many AWS services in one container, already named in ADR-0002. Now needs an account, and it is a third-party reimplementation.
- **ElasticMQ:** a small, free, SQS-only server. Third-party, and covers only part of the SQS API.
- **AWS emulator (official):** published by AWS, runs locally without an account. Fidelity measured below.

The scores below were measured only for the AWS emulator. We have no matching run for LocalStack or ElasticMQ, so this is not a side-by-side comparison. It checks that the chosen emulator is good enough for our use.

## Fidelity scores

Source: `scores.json.gz`, scored 2026-11-13 against emulator commit `1874aea`. Each unit is a scenario run against both AWS and the emulator.

- **Wire** units compare the HTTP response (status and body) step by step.
- **Behavioral** units check an observable behavior (ordering, visibility, redrive and so on).

| Scope | Units | Pass | Fail | Pass rate |
| --- | --- | --- | --- | --- |
| SQS only, behavioral | 306 | 287 | 19 | 93.8% |
| SQS only, wire | 29 | 13 | 16 | 44.8% |
| SQS only, total | 335 | 300 | 35 | 89.6% |
| SQS with other services (IAM, KMS, CloudFormation...) | 1201 | 829 | 362 | 69.6% (10 skipped) |
| Whole emulator, all services | 43548 | 27046 | 16419 | 62.2% (83 skipped) |

SQS on its own scores well above the emulator average, and every behavior from the Context list passes, including:

- `sqs.send-receive-delete-lifecycle`, `sqs.e2e-work-queue-pattern`
- `sqs.visibility-timeout-natural-expiry`, `sqs.change-message-visibility-extends`, `sqs.change-message-visibility-zero-makes-immediately-visible`
- `sqs.receive-count-increments`, `sqs.dead-letter-queue-redrive-after-max-receive-count`, `sqs.dlq-move-withheld-until-the-maxreceivecount-th-delivery`
- `sqs.long-polling-wakes-on-message-arrival`, `sqs.long-poll-blocks-on-empty`
- `sqs.concurrent-receive-no-duplicate-delivery`, `sqs.standard-queue-concurrent-producers-and-consumers-lose-no-message`
- `sqs.batch-send-partial-failure`, `sqs.delete-message-batch-partial-failure`

### Failures that matter to us

- `sqs.standard-queue-holds-more-than-one-thousand-messages`: a backlog above 1000 messages may not behave like AWS. Load tests and large-backlog tests must run against real SQS.
- `sqs.redriven-message-restarts-its-receive-count-and-dead-letters-again-at-maxreceivecount`: after a message is moved back from the SQS DLQ, its receive count may not restart. We don't redrive from the SQS DLQ in normal flow (our DLQ lives in Postgres), so this only affects manual operations.
- `sqs.client-on-the-queue-url-host-sends-and-receives-on-that-queue`, and wire body mismatches on `CreateQueue`, `GetQueueUrl` and `ListQueues`: queue URLs differ from AWS. Code must take the URL from config or `GetQueueUrl` and never build or parse it, and the SDK endpoint must be set explicitly.
- Error codes differ in some cases (for example `QueueDoesNotExist` 400 where AWS returns `InvalidAddress` 404). Code and tests must not branch on exact SQS error codes.

### Failures we can ignore

- FIFO-only checks: we use a standard queue.
- Query protocol and raw JSON request checks: the AWS SDK for JavaScript v3 uses the JSON protocol.
- IAM policy conditions, SSE, and message move task details: not used locally.

### Not covered by the scores

- SQS fair queues (needed by [ADR-0004](0004-tenant-fairness.md)). No unit tests them, so support still needs checking. Until it is confirmed, the ADR-0004 fallback applies: local runs use a plain shared queue and fairness is only tested against real SQS.

## Decision

We use the official AWS emulator for SQS in local development, integration tests and CI, run from Docker Compose next to Postgres.

## Consequences

- No account or token is needed to run the project or its CI.
- The behaviors the delivery pipeline depends on pass in the emulator, so integration tests against it are meaningful.
- Some gaps stay: backlogs above 1000 messages, queue URL shape, exact error codes, and fair queues. Tests that depend on them run against real SQS before production, as ADR-0002 already required.
- Fidelity can change between emulator releases, and the scores above only hold for commit `1874aea`. On Windows we build the image ourselves, and AWS's Dockerfile downloads the emulator RPM from an LTS/latest URL, so a rebuild can silently install a different version. Our Dockerfile must download a versioned RPM URL instead, and verify its checksum if AWS publishes one. When we upgrade, we re-check the scores.
- The emulator sends anonymous usage data by default. This is a public repo that anyone can clone, so Compose and CI turn it off with `EMULATOR_TELEMETRY=off`.
- The emulator keeps its state in memory, so every restart wipes the queues. The app or an init step must create the queues at startup, and doing it twice must be safe. Otherwise the first `docker compose restart` breaks the dev loop.
- The emulator serves HTTPS on port 9297 and writes its own credentials file. The SDK config and CI must trust its certificate and use those credentials. The setup details belong to the Compose task.
- `docs/design.md` and ADR-0004 now point here instead of LocalStack.
