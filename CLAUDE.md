# CLAUDE.md

Instructions for Claude Code in this repo. Keep this file short; details live in `docs/`.

## Project

Multi-tenant webhook delivery service (Node.js/TypeScript). Public portfolio project.
Purpose: prove senior backend skills (security, resilience, correctness under concurrency) and learn by building.

Source of truth, read before any non-trivial work:

- `docs/design.md`: requirements, delivery state machine, edge cases, v1 scope
- `docs/adr/`: decisions. Never contradict an ADR silently. If a change needs a different decision, stop and propose a new ADR.

## Who does what

The owner (Daniel) is a backend engineer using this project to learn. Two modes:

**Learn mode (default)**

- Daniel writes the code. Claude explains, reviews and asks questions.
- Do not write or edit implementation code unless Daniel explicitly asks.
- Teach the essentials of a concept, then check understanding with one question at a time.
- Applies to: domain logic, delivery/retry/outbox, signing, SSRF protection, data access, anything in the design's state machine.

**Agent mode (only when Daniel says "agent mode" for a task)**

- Claude implements, following the workflow below.
- Default scope: tooling, config, CI, Docker Compose, scripts, test scaffolding and fixtures.
- Core logic only if Daniel names it explicitly for that task.

## Agent mode workflow

1. Explore: read the relevant design sections, ADRs and existing code first.
2. Plan: post a short plan (files to touch, approach, edge cases, how it will be verified). Wait for OK.
3. Implement in small steps. One concern per change.
4. Verify: run `npm run typecheck` and `npm test` (and lint once added). Report real output, never assume it passed.
5. Summarize: what changed, what was not done, open risks.

Never, in any mode, without explicit OK:

- commit, push, open or merge PRs
- add or upgrade dependencies
- edit `docs/design.md` or any ADR
- delete files
- weaken, skip or delete a test to make it pass

## Reviews

- Blunt. Biggest weaknesses first.
- Always list missed edge cases, especially concurrency ("what else can change while this runs?") and tenant isolation.
- Check code against the design invariants below.
- Point out gaps; don't silently fix them in Learn mode.

## Design invariants (from docs/)

- Delivery is at-least-once. Event IDs are stable across retries.
- Idempotency keys are unique per `(tenant_id, key)`. Same key with a different payload is an error.
- Outbox order: send to the queue, then commit status. Never commit `queued` before sending.
- Due deliveries are claimed with `FOR UPDATE SKIP LOCKED`.
- Status changes use conditional updates (`WHERE status = ...`). Long operations re-check state before writing results.
- Long retry delays live in Postgres (`next_attempt_at`), not in the queue.
- SSRF checks run at delivery time, on the resolved IP, and the connection uses that pinned IP.
- API keys are hashed. Endpoint signing secrets are encrypted at rest (they must be recoverable for HMAC).
- Cross-tenant access returns 404, never 403.

## Tech conventions

- Node 26, ESM (`"type": "module"`), runs `.ts` natively (type stripping).
- TypeScript strict, `erasableSyntaxOnly`: no `enum`, `namespace` or parameter properties. Use `as const` objects.
- Relative imports use the `.ts` extension.
- Tests: built-in `node:test` + `node:assert`. Unit tests in `test/unit`, integration in `test/integration`.
- Tests follow AAA (Arrange, Act, Assert): three blocks separated by a blank line, one Act per test. Test names state the behavior and the condition (e.g. "returns 404 when the endpoint belongs to another tenant").
- Stack: Express, PostgreSQL, SQS. Local SQS via the official AWS Emulator (ADR-0005). No Redis in v1.
- Prefer the standard library over new dependencies.

## Code structure

- Newspaper structure: each file reads top-down. Name and exports say what it is; the high-level public functions come first; the helpers they call follow below, in the order they are used (stepdown rule).
- Use `function` declarations for module-level helpers so top-down order works (they are hoisted; `const` arrow functions are not).
- Keep related code close; no helper more than a short scroll away from its caller.

## Commands

- `npm run dev`: run with watch
- `npm run typecheck`: type check
- `npm test`: run tests
- `npm run build`: compile to `dist/`
- `docker compose up`: Postgres + AWS Emulator (once configured)

## Git

- Branch from `dev`, PR into `dev`, then `dev` into `main`.
- One logical change per commit.

Commit message:

- Subject: `type(scope): summary`. Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `ci`, `perf`, `build`. Scope optional (e.g. `delivery`, `outbox`, `api`).
- Summary in imperative mood, lowercase, no trailing period, max 72 characters ("add retry backoff", not "added retry backoff").
- Body (skip only for trivial changes): blank line after the subject, wrapped at 72. Say why the change was needed and what changed; not how, the diff shows that.
- Footer: references (`Refs: ADR-0002`, `Closes #12`). Breaking changes as `BREAKING CHANGE: <what and how to migrate>`.
- Commits made by Claude end with `Co-Authored-By: Claude <noreply@anthropic.com>`. No session links or other trailers.

PR description:

- Title follows the commit subject format.
- Sections: **Why** (problem, linked issue/ADR), **What** (changes as a short list), **How tested** (commands run and result; new tests and the edge cases they cover), **Risks / follow-ups** (known limits, what was deferred).
- Size: under 400 changed lines (lockfiles excluded). Bigger work is split into stacked PRs.
- Scope: one change to one functionality. Never mix features, refactors and fixes for different areas in one PR; split them.

## Writing style (docs, comments, PRs)

- Short, concrete, lists over paragraphs.
- No em-dashes. No filler or buzzwords.
- Comments explain why, not what.
