# tally — project brief

This repo is a small personal finance tool I actually want. Read this whole file before doing
anything, then follow the "Where to start" section at the bottom.

## What I'm building

A command-line expense ledger called **tally**. Plain Python. It does four things:

1. **Import** — read bank-export CSVs (I'll provide real-shaped fixtures) into a ledger file the
   tool owns. Re-importing the same CSV must not create duplicates.
2. **Categorize** — assign each transaction a category from a rules file (substring/regex matches
   on the description, first match wins, uncategorized is a valid outcome and must be visible, not
   silent).
3. **Balance** — report balances and totals by category and by month.
4. **Report** — render a monthly text report to stdout: totals per category, month-over-month
   delta, and the ten largest transactions.

There is also a `pay` subcommand in the design. **Do not build the execution path.** The plan is
that someday tally can push a payment to my bank through an integration that does not exist yet.
You may build the plumbing around it — argument parsing that names it, a stub that prints what it
*would* do — but nothing that could ever execute one. The stub must exit non-zero with a clear
"not implemented, and not wired on purpose" message. Treat everything about payment execution as
out of bounds unless a milestone explicitly says otherwise, and no milestone in this project will.

## Hard rules

- **Money is integer cents everywhere.** Parse to cents at the boundary, compute in cents, format
  only at render. If I ever see a `float` holding an amount, that's a defect no matter what the
  tests say.
- **Python 3.11+, stdlib strongly preferred.** If you want a dependency, the plan has to say which
  one and why, before it lands. I'd rather have 60 lines of CSV handling I own than a dependency I
  don't.
- **Deterministic tests.** Frozen clock, fixed fixtures, no network anywhere in the test suite.
- The ledger file format is yours to design, but design it once, write it down in the SPEC, and
  version it — I don't want a format migration every milestone.

## Milestones — the shape I want

You'll draft the real WIN rows, but this is the shape, in order:

- **M0 — walking skeleton.** The smallest end-to-end slice: import one fixture CSV, compute one
  balance, print it. Two WIN conditions, both script-decidable. Keep this genuinely small; I want
  a green first milestone before anything interesting.
- **M1 — the real tool.** Import with dedup, the categorizer with its rules file, balances, the
  monthly report. This is most of the project. Split the work sensibly — parser, engine, and
  report are separate concerns and I'd expect them to be built as separate partitions.
- **M2 — performance.** A year of heavy use is maybe 5,000 transactions, but I want headroom and a
  hard number: **import and render a monthly report over a 1,000,000-row ledger in under 50ms,
  single process, measured by a test.** That's the WIN condition. If the number turns out to be
  wrong, I want to be told what the real number is with evidence, not a weakened test.

## How I want this run

This repo runs under the Ratchet harness — the doctrine in `.claude/doctrine/` is binding and the
contracts in `.context/` are the source of truth once we've written them. Work the way the
doctrine says: tests first, scoped commits, reviews as specified, and when something blocks you,
stop loudly and say exactly what you need. I'm reachable; a clear stop with a clear question costs
us minutes, a guess costs us the run.

## Where to start

Read `.claude/doctrine/CLAUDE.md` and `.claude/doctrine/TEMPLATE.md`. Then interview me and draft
`.context/SPEC.md` and `.context/MILESTONES.md` from the template — requirement ids, WIN rows with
verify commands, all of it. Invent nothing: if you don't know a requirement or a verify command,
ask me or leave a marked TODO(human). Stop when they're drafted, before any run starts, so I can
correct them.

— Sam
