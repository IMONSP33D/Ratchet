# INDEX.md — the run register

**Owner: the `retro` seat.** One row per run. Appended, never rewritten; a consolidation adds a row,
it does not edit existing ones. A correction to an earlier row's outcome token goes in the correcting
retro's **§9**, not by editing the row here — one telling per decision.

## Why this file has a rule attached to it

In the source pipeline **this register was never populated across nine retrospectives**, and the gap
was rediscovered and refiled **three separate times** — once as an audit finding, once as a
reconstruction note in the file itself, and once more two runs later, still unresolved. The register
that the outcome tokens feed did not exist in practice for the entire life of the corpus, so nothing
could answer "what happened in run 4?" without opening five documents.

The cause was not difficulty. It was position: appending the row was the least interesting thing in a
long retro and it sat wherever attention ran out. So:

- **Updating `INDEX.md` is the retro's LAST STEP**, stated as such in `_TEMPLATE-run-retro.md` §10.
- **`check_done.py` verifies the row exists for this run number** before the run can reach ship tier.
  A retro without its index row is not finished, and the checker — not the author — says so.
- The one-line result is the retro's own §10 verdict, verbatim. It is not rewritten here, because a
  second telling of a conclusion is how two tellings come to disagree.

The `outcome` token comes from the CLOSED set — **`shipped` `nogo` `halted` `abandoned` `superseded`
`awaiting-ship`** — and must match the run document's filename token exactly. A token outside the set
is a parse failure, not a stylistic choice; the source corpus shipped a `control-layer` token that no
tool could read, and the document had to declare its own real token in its first lines.

**A token is a claim about the world when it was written.** Re-measure the predecessor's every run
(§9) — the source corpus caught a false `shipped` this way, and then caught its own correction going
stale two runs after that.

## Register

| run | milestone | outcome | date | PR | one-line result |
|---|---|---|---|---|---|
| 000 | — | `superseded` | install | — | Harness installed; learning loop seeded with ten lessons from a predecessor nine-run corpus and three install-time human actions — no local evidence yet, first consolidation must re-evaluate all of it. |

<!--
Row format (frozen - parsed by check_done.py):
| NNN | M<n> or "-" | shipped \| nogo \| halted \| abandoned \| superseded \| awaiting-ship | YYYY-MM-DD | #<n> or "-" | one sentence, verbatim from the retro's section 10 |

Consolidation rows are marked in the milestone column as `CONSOLIDATED NNN-NNN`.
Run 000 is the install seed. Its token is `superseded` because it is a row with no run behind it,
kept so the register is never empty and the numbering has an origin.
-->
