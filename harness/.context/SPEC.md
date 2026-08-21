# SPEC.md — Development Specification: {{PROJECT_NAME}}

<!-- ============================================================================
     THIS FILE IS A STUB. A HUMAN MUST FILL IT IN BEFORE THE FIRST RUN.
     Every heading below is mandatory. Delete the worked examples, keep the shape.
     Guidance lives in HTML comments; leave them or delete them, agents ignore them.
     Read .context/CONVENTIONS.md first — it defines every convention this file uses.
     ============================================================================ -->

Version 0.1 · <!-- YYYY-MM-DD --> · Companions: `CLAUDE.md` (how to work), `PIPELINE.md` (stage
mechanics), `CONVENTIONS.md` (structural conventions), `MILESTONES.md` (build order & win conditions).

**Who owns it.** Human-owned, Tier 2b. Agents MUST NOT edit this file. It is the frozen contract
source: every requirement here has a stable id, and tests, commits, WIN rows and `DECISIONS.md`
entries cite those ids. RFC 2119 keywords apply.

**What "frozen" means.** An agent may not change a requirement to make a test pass. Where reality
contradicts this document, the orchestrator records a `DECISIONS.md` entry choosing the safest
reversible option and, if it is material, raises a Decision Card. The document changes by human edit,
never by agent edit.

---

## 1. Purpose, scope, non-goals

<!-- One paragraph each. The non-goals section is the one people skip and the one that stops
     scope creep three milestones later. Name what this system will NOT do, especially the
     adjacent thing a reasonable person would assume it does. -->

**Purpose.** <!-- What the system does, in one paragraph, in terms of the outcome it produces. -->

**In scope.** <!-- The environments, data sources, platforms and modes this project covers. -->

**Non-goals.** <!-- Explicit exclusions. Each one is a boundary a future milestone may not cross
                   without a human edit to this file. -->

> **Worked example.**
> **Purpose.** Ingest records from an upstream feed, normalise them into a canonical schema, persist
> them durably, and expose a queryable report surface with an auditable derivation for every figure.
> **In scope.** One upstream feed, local persistence, a CLI report surface, a localhost health endpoint.
> **Non-goals.** Multi-tenant isolation; any UI beyond the health endpoint and the CLI; real-time
> streaming (batch only); write-back to the upstream feed.

---

## 2. Requirement-ID taxonomy (declaration)

<!-- Declare the namespaces this project uses. The default five are below. If you add one,
     state its form, what belongs in it, and — the part people forget — what ARTEFACT proves
     one. A requirement class with no provable artefact cannot be cited by a WIN row. -->

| Prefix | Class | Form | Proven by |
|---|---|---|---|
| `REQ-` | Functional requirement | `REQ-<MODULE>-<nn>` | A named passing test citing the id |
| `SEC-` | Security requirement | `SEC-<nn>` | A named passing test, or a `security-auditor` finding closed |
| `TEST-` | Testing requirement | `TEST-<nn>`, properties `TEST-P-<nn>` | The suite's own configuration and gates |
| `INV-` | Invariant | `INV-<DOMAIN>-<nn>` | A property test over generated inputs |
| `AV-` | Assumption to verify | `AV-<nn>` | Captured raw evidence + a `DECISIONS.md` entry (§8) |

Module tokens in use: <!-- list them, e.g. INGEST NORM STORE REPORT API OPS -->

Ids are permanent, never reused, never renumbered. A replaced requirement gets a NEW id; the old is
marked SUPERSEDED in place.

---

## 3. Architecture (component responsibilities)

<!-- A diagram or a short list: what the components are and what each one is responsible for.
     This is what the architect partitions against, so the boundaries here become the partition
     boundaries at Stage 2. Draw them where you want the work to fan out. -->

```
<!-- component -> component data flow -->
```

<!-- Then one short paragraph on the execution model: process model, concurrency, the main loop
     or entry point, and what the tests substitute for it. -->

---

## 4. Repository layout (canonical)

<!-- The canonical tree. M0's first WIN row usually asserts this exactly, so write it as the
     shape you want to enforce, not the shape you happen to have. -->

```
{{PROJECT_NAME}}/
├── .context/            # human-owned contracts (this file, CLAUDE.md, PIPELINE.md, ...)
├── .claude/             # control layer — never edited by agents
├── docs/evidence/       # WIN-row proof, probes
├── <source tree>/
└── <test tree>/
```

---

## 5. Core domain models

<!-- The types that cross module boundaries, each with its fields. Two rules that are worth
     stating as REQ- ids rather than prose, because they are the ones that erode:
       - all external payloads are parsed into these types at the boundary;
       - business logic never reads a raw untyped payload. -->

> **Worked example.**
> `Record`: `id`, `source`, `observed_at`, `payload_version`, `fields` (typed), `ingested_at`.
> `ReportRow`: `bucket`, `bucket_start`, `count`, `total`, `derivation_ref`.
>
> **REQ-DM-01** All inbound external payloads MUST be parsed into a declared model at the boundary;
> business logic MUST NOT read raw untyped structures.
> **REQ-DM-02** Unknown inbound fields are ignored but counted in a metric; a missing required field
> raises a typed validation error routed to the error path, never a silent default.

---

## 6. Formulas & golden values

<!-- Every derived number the system will be trusted on. State the formula, then the goldens:
     hand-derived expected values, with the derivation shown. Per CONVENTIONS.md §6:
       - every golden becomes a named test with the value as a LITERAL;
       - the derivation goes in the test docstring;
       - a golden is NEVER generated by the implementation.
     If this project has no derived numbers, write "None — this project derives no numeric
     results" and say so explicitly. An empty section reads as an oversight. -->

> **Worked example.**
> ### 6.1 Bucket totals — `<module>/aggregate.py`
> `bucket_total(rows) = sum(r.amount for r in rows if r.knowable_at <= bucket_end)`, integer units.
>
> **REQ-AGG-01** Totals are computed in integer units; no floating-point accumulation anywhere in the
> aggregation path.
> **REQ-AGG-02** Goldens (hand-derived):
>
> | rows | bucket_end | total |
> |---|---|---|
> | `[(10, t0), (20, t1)]` | `t1` | 30 |
> | `[(10, t0), (20, t2)]` | `t1` | 10 |
> | `[]` | `t1` | 0 |
>
> Properties (**TEST-P-01**): total ≥ 0 for non-negative inputs; total is monotone non-decreasing as
> `bucket_end` advances; an empty input yields exactly 0.

---

## 7. Functional requirements by module

<!-- One block per module from §3. Each requirement: a stable id, a MUST/SHOULD/MAY statement,
     and stated so it can FAIL. If you cannot describe the input that violates it, rewrite it. -->

> **Worked example.**
> **Ingest (`<module>/ingest.py`)**
> **REQ-INGEST-01** The reader MUST accept records in the declared payload versions and reject any
> other version with a typed error naming the version seen and the versions accepted.
> **REQ-INGEST-02** A transient upstream failure (timeout, 5xx) MUST be retried with bounded
> exponential backoff and full jitter: base 0.5s, cap 30s, maximum 6 attempts. No retry hint from the
> upstream is assumed to exist.
> **REQ-INGEST-03** Every ingest operation MUST carry an idempotency key; a retried operation MUST NOT
> produce a duplicate record.
>
> **Persistence (`<module>/store.py`)**
> **REQ-STORE-01** Parameterised queries only.
> **REQ-STORE-02** Every persisted row carries `observed_at` and `ingested_at`; a row MUST NOT be
> writable without both.

---

## 8. Configuration

<!-- Every tunable, with its default, in one place. Rule: a value that appears here MUST NOT
     appear as a literal in logic. This is what makes an AV outcome a config change rather than
     a code change, and it is what the "no hard-coded constants" gate checks. -->

Top-level keys and their defaults:

| Key | Default | Requirement | Notes |
|---|---|---|---|
| <!-- `ingest.batch_size` --> | <!-- `500` --> | <!-- REQ-INGEST-01 --> | <!-- --> |
| <!-- `ingest.max_attempts` --> | <!-- `6` --> | <!-- REQ-INGEST-02 --> | <!-- --> |

**REQ-CFG-01** Secrets come only from environment variables, never from a config file. Config
validation fails fast with a message naming the offending key and the constraint it violated.

**REQ-CFG-02** A value declared in this section MUST NOT appear as a literal in logic. Where a value
is volatile and externally determined, it is an `AV-` item (§9) and its default here is the
*conservative* branch.

---

## 9. Security requirements

<!-- SEC- ids. Every one of these should be independently testable. The domain pack's
     SECURITY_BOUNDARY_FILES list should name the files that implement the ones marked as the
     auth/secret boundary — those files are Hard Stop 1. -->

> **Worked example.**
> **SEC-01** Secrets via environment only; a local `.env` is gitignored; `.env.example` documents the
> names with placeholder values.
> **SEC-02** Private key material lives outside the repository tree, mode `0600`, enforced at startup;
> never read into logs or error messages.
> **SEC-03** A logging redaction filter masks credential headers, signatures, key contents and API
> tokens. Unit-tested: a crafted record comes out masked.
> **SEC-04** All inbound external data is validated (REQ-DM-01/02); numeric bounds checked.
> **SEC-05** Parameterised queries only, enforced by lint rule and review.
> **SEC-06** Dependencies pinned by lockfile; the dependency audit is clean in CI; waivers only via a
> `DECISIONS.md` entry naming the CVE and the mitigation.
> **SEC-07** Static security lint enabled; violations fail the lint gate.
> **SEC-08** No dynamic evaluation (`eval`/`exec`/deserialisation) of external data.
> **SEC-09** A kill mechanism halts the operational path within one iteration; tested with a fake clock.
> **SEC-10** Pre-commit hooks installed and firing: format, lint, private-key detection, large-file check.

---

## 10. Testing requirements

<!-- TEST- ids. These constrain the SUITE, not the system. The coverage gates and the critical
     set below are what `{{VERIFY_CMD}}` enforces. -->

> **Worked example.**
> **TEST-01** TDD per `CLAUDE.md` law 1: a failing test precedes implementation for every requirement;
> test names and docstrings reference ids (`CONVENTIONS.md` §8). Test authorship and implementation are
> separated seats.
> **TEST-02** Tiers and markers: `unit` (default; network blocked; no sleeps; frozen clock; seeded RNG),
> `integration` (mocked transport, recorded fixtures), `e2e` (opt-in, needs credentials, excluded from
> CI), `slow`.
> **TEST-03** Coverage gates: total ≥ 85%; the critical set (§12) ≥ 95%, enforced by a script reading
> the coverage report — not by a human reading a percentage.
> **TEST-04** Property-based tests required for: <!-- list the modules --> and for every `INV-`.
> **TEST-05** Golden tests: every §6 golden, with hand-derived expectations as literals.
> **TEST-06** CI runs lint, type, coverage and audit on every push and PR; any failure blocks. The `e2e`
> tier never runs in CI.
> **TEST-07** Flake policy: zero tolerance. A flaky test is a bug — fix it, or quarantine it with a
> `DECISIONS.md` entry and a tracked issue. Never delete.
> **TEST-08** Recorded fixtures MUST be scrubbed of identifiers before commit; a scrub check runs in
> `{{VERIFY_CMD}}`. Keys are not the only thing that leaks.

---

## 11. Invariants

<!-- INV- ids: relations that must hold at all times, property-tested over generated inputs.
     These are the requirements that survive refactoring, so they are worth stating precisely. -->

> **Worked example.**
> **INV-LEDGER-01** `net = gross − adjustments`, exact in integer units, in every bucket.
> **INV-LEDGER-02** Σ(hourly buckets) = Σ(daily buckets) = total, exact, property-tested over generated
> event streams (`TEST-P-03`).
> **INV-LEDGER-03** Every reported figure is derivable from the persisted event log alone; replaying the
> log reproduces it exactly.

---

## 12. Critical-file coverage set

<!-- The files where a coverage regression is a defect rather than a metric. Keep this list
     short and load-bearing: the money math, the security boundary, the parsers, the
     irreversible paths. This is the list the coverage gate script reads. -->

| File | Why it is critical |
|---|---|
| <!-- `<module>/aggregate.py` --> | <!-- every reported figure derives from it --> |
| <!-- `<module>/auth.py` --> | <!-- the security boundary --> |

Gate: ≥ 95% line coverage on every file in this set, enforced mechanically. Adding a file to this set
is a human edit; removing one requires a `DECISIONS.md` entry saying why it stopped being critical.

---

## 13. Observability & resource budgets

<!-- What the system logs, what it counts, and what it is allowed to consume. Budgets stated as
     numbers become WIN rows; budgets stated as adjectives become arguments. -->

> **Worked example.**
> **REQ-OPS-01** Structured JSON logs in production, human-readable in development; per-component
> loggers; every state transition, external call, rejection and error logged with its reason.
> **REQ-OPS-02** Steady-state budget: < 1 CPU core average, < 1.5 GB RSS, main-loop p95 under the
> configured interval.
> **REQ-OPS-03** A daily summary and a durable backup on a timer, with a stated retention window.

---

## 14. AV register — assumptions the agent MUST verify against live sources

<!-- The volatile external facts this design depends on. See CONVENTIONS.md §5.
     For each: the assumption, the CONSERVATIVE default, what it is verified against, and the
     milestone where verification is a WIN row. An AV item nobody is required to verify is a
     comment, not a register entry.
     Lifecycle: open -> measured -> configured. Outcomes update CONFIG DEFAULTS and DECISIONS.md,
     never code literals. -->

| ID | Assumption (config-driven; never hard-coded) | Conservative default | Verify against | Resolves at |
|---|---|---|---|---|
| <!-- AV-01 --> | <!-- The upstream feed's rate limit and whether it advertises a retry hint --> | <!-- assume no hint; 6 attempts --> | <!-- a captured live response --> | <!-- M1 --> |
| <!-- AV-02 --> | <!-- Base URLs, header names, auth scheme --> | <!-- the documented values --> | <!-- a recorded round-trip --> | <!-- M1 --> |

**Rules.** While an item is open, the design MUST survive its unfavourable branch, and any result it
changes is reported for **both** branches, labelled. Ground truth read off a real artifact beats any
document, including this one. An AV verification that contradicts a frozen contract is a
`DECISIONS.md` entry and, if it moves a load-bearing constant, a Decision Card.

Verification of each item is a WIN row in the milestone named above. Items that can regress carry a
re-check cadence in the Notes column of `MILESTONES.md`'s open-items ledger.
