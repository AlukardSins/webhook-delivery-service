# ADR-0003: Retention

- Status: Accepted (deferred to post-v1)
- Date: 2026-11-09

## Context

Event history (events, deliveries and attempts) is kept in Postgres for 6 months. Without a limit, the tables grow forever and queries slow down. This ADR decides what happens to history older than 6 months, and what a tenant gets when they ask for it.

## Options considered

- **Delete:** cheapest and simplest, but tenants lose history they may need for audits or disputes.
- **Archive to long-term storage:** keeps the history at low cost, but reading it back is slower.

## Decision

History older than 6 months is archived to Amazon S3 and then deleted from Postgres. The archive is kept for another 6 months, so history is retained for 1 year in total.

- A daily job exports each month's history as compressed JSON files, stored per tenant and per month (for example `tenant_id/2026-05/`).
- After the export is verified, the rows are deleted from Postgres.
- The history API only returns the last 6 months. For older events it returns a clear error saying the data is archived.
- Tenants get archived history by requesting an export through the API. The export runs in the background and returns a download link. Tenants never access the archive directly, so one tenant can't read another tenant's data.
- The daily job also deletes archive folders whose month, taken from the path, is more than 12 months old. After that, the history is gone, and export requests for it return an error saying it was deleted.
- An S3 lifecycle rule that deletes archive files 6 months after they are written is kept as a fallback, in case the daily job stops running.
- Data deletion requests: history from the last 6 months is deleted from Postgres. Archive files are rewritten only when a request covers them: each affected file is replaced with a new file that leaves out the deleted data. Because the cleanup goes by the month in the path, a rewritten file is still deleted on schedule.

## Consequences

- S3 is another cost if the service is deployed, but storage is cheap, and it can move to a colder storage class over time.
- Archived history is slower to get: tenants wait for an export instead of reading it from the API.
- Payloads can contain personal data. The 1-year limit keeps it from being stored forever, and deletion requests remove it sooner.
- Tenants who need history for longer than 1 year must export it before it is deleted.
- If the daily job stops running, the fallback rule counts from when a file was written, so a rewritten file can stay up to 6 months past its rewrite. We accept this for a backup path.
