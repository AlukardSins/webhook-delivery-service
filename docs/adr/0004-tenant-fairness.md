# ADR-0004: Tenant fairness

- Status: Accepted (deferred to post-v1)
- Date: 2026-11-10

## Context

Delivery capacity is shared by volume, not split evenly: each tenant has a reserved minimum, and tenants that send more can use the spare capacity above it (see [Non-functional](../design.md#non-functional)).

[ADR-0002](0002-message-queue.md) puts every delivery in one shared SQS standard queue. In a single queue, a tenant that publishes 1M events fills the queue ahead of everyone else, so other tenants wait behind that backlog and no minimum can be guaranteed.

This ADR decides how deliveries are split across queues, and how workers choose which queue to read next.

## Options considered

- **One shared queue with SQS fair queues:** messages are tagged with the tenant ID as `MessageGroupId`, and SQS keeps a noisy tenant from delaying the others. Few changes, but it reduces the noisy-neighbour effect rather than guaranteeing a minimum.
- **One queue per tenant:** full isolation, and per-tenant queue depth comes for free. But workers must poll every queue, including empty ones, which makes the 5 s first-attempt target hard to meet with thousands of tenants, and every tenant adds a queue, a DLQ, permissions and alarms to manage.
- **Hybrid:** small tenants share one fair queue, and a tenant gets a dedicated queue once its volume justifies it. Workers poll one shared queue plus a few dedicated ones.

## Decision

We use the hybrid: one shared fair queue for most tenants, and dedicated queues for tenants we promote.

### Queues

- **Shared queue:** an SQS standard queue with fair queues enabled. Every message sets `MessageGroupId` to the tenant ID.
- **Dedicated queues:** one SQS standard queue per promoted tenant, each with its own SQS dead-letter queue (redrive policy), as in [ADR-0002](0002-message-queue.md).
- Each tenant row stores its queue. Empty means the shared queue. The publish path, the outbox job and the retry scheduler, which also sends manual retries, all read it to choose where to send a delivery.

### Capacity

- Each tenant has a reserved minimum of 100 deliveries per second. This is a conservative estimate, to be tuned with real metrics. A tenant's unused reserve is not held idle: it goes to the spare capacity.
- Capacity left over goes to the queues with the largest backlog, so tenants that send more get more.
- Inside the shared queue, the minimum per tenant is best-effort: fair queues keep quiet tenants from waiting behind a noisy one, but don't reserve capacity for them. A tenant that needs a guaranteed minimum gets a dedicated queue.

### Promotion

- Promotion is manual. When tenants compete for spare capacity, we review the per-tenant metrics and decide case by case whether a tenant gets a dedicated queue.
- A promotion review is triggered when:
  - A tenant sustains 1000 deliveries per second or more.
  - The shared queue reaches 10,000 deliveries per second. Standard queues have nearly unlimited throughput, so this is a review ceiling, not a hard limit: the shared queue keeps working above it, and we review the tenants with the highest throughput in it first.
- To promote a tenant, we create its queue and update the tenant row. New deliveries go to the new queue, and messages already in the shared queue are delivered from there as usual. Messages carry only the delivery ID, so nothing has to be moved.
- Demotion works the same way in reverse: point the tenant back at the shared queue, let the dedicated queue drain, then delete it.

## Consequences

- A noisy tenant in the shared queue can still slow others down a little, until it is promoted.
- Each dedicated queue adds a queue, a DLQ, permissions and alarms to manage, which is why only promoted tenants get one.
- During a promotion or demotion, a tenant's deliveries are spread across two queues for a while. This can reorder or duplicate deliveries, which our [delivery guarantee](../design.md#delivery-guarantee) already allows.
- Per-tenant queue depth comes from CloudWatch for dedicated queues. For the shared queue it has to be computed from deliveries in Postgres.
- The local SQS emulator's support for fair queues needs checking (the [ADR-0005](0005-local-sqs-emulator.md) fidelity scores don't cover it). If it's missing, local runs use a plain shared queue and fairness is only tested against real SQS.
- A slow receiver holds a worker for up to the 10 s timeout, so keeping 100 deliveries per second against slow endpoints can take up to 1000 concurrent deliveries per tenant. Worker capacity has to be sized for the tenants active at the same time, not only for the per-second rate.
