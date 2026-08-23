# UPGRADING.md — Changing the Harness Mid-Project · {{PROJECT_NAME}} · Ratchet

**What this is.** The doctrine for changing the control layer of a project that is already running:
how a human takes a newer Ratchet scaffold without losing this project's work, and — the part that
matters more — what the **agent** does when the pipeline itself is what needs to change.

**Where it lives and who owns it.** `.claude/doctrine/UPGRADING.md`. Harness-owned doctrine, Tier 2b:
it ships with Ratchet, it is identical in every project, and it is replaced wholesale by
`ratchet-update.sh`; if you edit it anyway, the updater will report the edit and keep your copy as
`UPGRADING.md.local-<timestamp>` rather than discard it. **Humans: you do not need to edit this file.**
Agents MUST NOT edit it, and no approval lifts that.

**Read this when:** a new Ratchet version ships; or a run keeps hitting the same gate and the gate
looks wrong; or someone is about to hand-edit something under `.claude/`.

---

## 1. The two different problems, which have two different answers

People arrive here with one of two problems and reach for the same tool. They are not the same
problem and the same tool is wrong for one of them.

| | **Upstream scaffold changed** | **This project needs the pipeline to change** |
|---|---|---|
| Looks like | "Ratchet 1.1.0 is out" | "the scope guard blames the wrong actor and it has cost us three runs" |
| Origin of the change | someone else's repo | this run's evidence |
| Correct instrument | **`ratchet-update.sh`** (§2) | **the supervisor-changeset pattern** (§4) |
| Who applies it | a human, one command | a human, after an independent review |
| Wrong instrument | hand-editing hooks to match a release note | `ratchet-update.sh` — there is nothing upstream to pull |

They compose in one direction only, and the direction is the whole point:

> The changeset pattern produces a **diagnosis**. The right destination for that diagnosis is
> **upstream**, so that the next `ratchet-update.sh` brings the fix back as ordinary harness content
> that this project no longer owns. Patching it locally instead converts every future update into a
> merge, permanently. See §5 before you choose that.

---

## 2. How a human runs the updater

```sh
# 1. See what would change. Writes nothing, works offline against a local bundle.
bash ratchet-update.sh --check --target . --from /path/to/ratchet-1.1.0
bash ratchet-update.sh --check --target . --from ./ratchet-1.1.0.zip

# 2. Rehearse it. Still writes nothing; runs the real installer in --dry-run.
bash ratchet-update.sh --apply --dry-run --target . --from /path/to/ratchet-1.1.0

# 3. Do it.
bash ratchet-update.sh --apply --target . --from /path/to/ratchet-1.1.0
```

### 2.1 What it touches, and what it will not

Every file in the repository lands in exactly one of three classes. The classifier's **default is
USER**, so a path nobody anticipated is a path nobody overwrites.

| class | what is in it | what happens |
|---|---|---|
| **HARNESS** | `.claude/hooks/**` (except `domain.config.sh`), `.claude/agents/**`, and the doctrine docs `.claude/doctrine/CLAUDE.md`, `PIPELINE.md`, `TEMPLATE.md`, `UPGRADING.md` | **replaced wholesale.** These are the harness's, not yours. Local edits are detected first (§2.2). |
| **MERGED** | `.claude/settings.json` | **merged.** Permissions are unioned, hooks re-wired, your own entries kept, backed up first. Our `deny` beats your `allow`, because `deny` is the class that cannot be lifted at runtime. |
| **USER** | `.claude/hooks/domain.config.sh`, `.context/SPEC.md`, `.context/MILESTONES.md`, `.context/DECISIONS.md`, `.context/archive/**`, `.agent-development/**`, `.pipeline/**`, `secrets/**`, `docs/evidence/**`, your root `CLAUDE.md`, **and every path not named above** | **never touched.** |

One sanctioned exception: the updater **appends** a row to
`.agent-development/PENDING-HUMAN-ACTIONS.md` when the update needs a human. That register is
append-only by design and exists to be appended to. Nothing else in the USER partition is written.

### 2.2 Local modifications to harness files

At install and at every update, the updater records `.claude/.ratchet-manifest`: a checksum per
harness file, as written. At the next update it asks a decidable question — *does this file still
match what we wrote?* — instead of the undecidable one, *is this difference ours or theirs?*

- **Unchanged** → replaced silently. That is what an update is.
- **Changed by you or by an agent** → listed by name, and the previous contents are kept beside the
  file as `<file>.local-<timestamp>`. A `.local-*` name matches no hook glob (`*.sh`, `*.py`) and is
  wired into nothing, so it is inert: a diff waiting for you, not a second control layer.
  `--force-overwrite-modified` skips the copies; the full backup still has them.
- **Changed, and the change is one of the never-escalatable control-set files**
  (`settings.json guard.sh scope-guard.sh hooklib.sh escalation-lib.sh approve.sh
  ratchet.config.sh`) → the same handling, reported at higher volume, plus a
  `control-set-drift-detected` row filed for a human. This is a warning and not a refusal on
  purpose: refusing would block the very update that restores the control layer to a known state.
- **No manifest at all** (an install that predates the updater) → every differing harness file is
  reported `UNVERIFIED` and preserved as `.local-*`. Nothing is assumed clean. Run
  `ratchet-update.sh --adopt-baseline` once, immediately after an install you trust, to make the
  question decidable from then on.

### 2.3 What makes it refuse

| condition | why | override |
|---|---|---|
| `.pipeline/run-active` exists | Swapping the gates mid-run means the run's second half is judged by different rules than its first, and nothing in the record says which half of the evidence was collected under which rules. | `--force`, and then say so in `DECISIONS.md` |
| the bundle is an older version | An accidental downgrade silently removes gates you are relying on. | `--allow-downgrade` |
| `jq` is absent | `settings.json` is the permission surface; merging JSON with `sed` means guessing, and a permissive entry that survives a bad guess reopens a wall. CONTRACT §0.3: a gate that cannot determine safety blocks. | none |
| no checksum tool | "Was this harness file edited?" would become a guess made immediately before overwriting the control layer. | none |
| the backup could not be written | An update without a backup is not an update, it is a hope. | none |
| no terminal and no `--yes` | An unattended process tried to replace the control layer. | `--yes` |

### 2.4 Backup and rollback

Before one byte is written, the whole `.claude/` tree (minus older backups) plus every doctrine doc
the update will rewrite is copied to `.claude/.backup-<version>-<timestamp>/`, and a `restore.sh` is
generated inside it. Rollback is one command, printed on success and again, loudly, on failure:

```sh
bash .claude/.backup-<version>-<timestamp>/restore.sh
```

It restores the control layer and **nothing else**. `.pipeline/`, `.agent-development/`, `secrets/`,
`docs/evidence/`, SPEC, MILESTONES and DECISIONS were never modified, so putting them back would be
a change rather than a rollback. The `PENDING-HUMAN-ACTIONS.md` row stays too: it is the record that
this happened.

**The updater never rolls back by itself.** If the hook suite goes red on the new harness, it says so
at maximum volume, prints the rollback command, and exits 1 — but it leaves the new tree in place. An
automatic rollback would leave you with a working harness and no evidence that the new one is broken,
which is how a broken release ships twice.

---

## 3. The agent-driven path: why you cannot fix this yourself

If you are an agent reading this mid-run because a gate is wrong: **you may not edit the control
layer.** `.claude/**` is Tier 2b and never-escalatable (CONTRACT §5.6). Not with an approval, not
with a Decision Card, not by putting it in the domain pack. `approve.sh` refuses those rule ids by
construction.

This is not distrust dressed up as policy. It is the one structural property the harness has: an
agent that can rewrite its own guardrails in response to being blocked by them has no guardrails.
The refusal has to hold in exactly the moment it is most inconvenient, or it is decorative.

But the corollary is real and the harness owes you an answer to it: **the party best positioned to
diagnose a control-layer defect is structurally forbidden from fixing it.** Five of five runs in the
source corpus died in the control layer, never in the engineering. Your diagnosis is the most
valuable artifact in the run. It needs somewhere to go that is not a hook file.

That somewhere is `.agent-development/proposals/`.

---

## 4. The supervisor-changeset pattern, and how it composes with the updater

Read `.agent-development/proposals/README.md` — it is the normative version. The shape:

| step | who | artifact |
|---|---|---|
| 1. **Changeset** | the orchestrator (the party barred from the control layer) | `SUPERVISOR-CHANGESET-NNN.md`: prioritised items, each naming **the invariant**, **every instance** of it, a verified reproduction, the site, and its position in the landing order |
| 2. **Review** | an independent reviewer, fresh context | `NNN-<date>-changeset-review.md`: ordering, omission against the open registers, per-item merit — opening with the **provenance caution**, because the changeset is the run's account of itself written by the party under review |
| 3. **Apply** | a human | `APPLY-NNN.md`: what landed, how it was verified, what is still owed |

Three details that are not optional, because each one was learned expensively:

- **Name the invariant, not the incident.** "`stop-gate.sh:412` blames the wrong actor" is a bug
  report. "Attribution below `exact` mode must report and never order a revert — here are all six
  sites" is a changeset item. The second one is fixable once; the first one recurs.
- **Every instance, in one item.** A one-site fix for a six-site invariant leaves five live and
  guarantees the same review cost again next month.
- **Ordering is the defect that hides.** The reviewer of the canonical changeset found all eleven
  items individually correct and **the priority order wrong in three places**, including a dependency
  the changeset asserted was absent while its own text contradicted that three times. A review that
  only grades items has skipped the part that pays.

### 4.1 Where the changeset should land

Default: **upstream.** A changeset that names an invariant and every instance of it is exactly the
input a scaffold maintainer needs. Send it there, and the fix arrives in this project as ordinary
harness content on the next `ratchet-update.sh --apply` — content this project does not own, does not
maintain, and does not have to re-merge forever.

Applying it locally instead is the subject of §5, and it is more expensive than it looks.

### 4.2 How the two instruments compose

```
  a defect you found  ->  SUPERVISOR-CHANGESET-NNN.md  ->  independent review  ->  upstream
                                                                                     |
  someone else's fix  <-  ratchet-update.sh --check/--apply  <----  new scaffold  <---+
```

The updater is the **inbound** channel and the changeset is the **outbound** one. If you find
yourself using the updater to deliver a change that originated in this project, you have crossed the
streams: there is nothing upstream to pull, and you are about to hand-edit a bundle.

---

## 5. The local-patch escape hatch, honestly framed

Sometimes a project genuinely must diverge — a regulator requires a wall the scaffold does not ship,
an internal tool needs a permission the default deny blocks. The hatch exists. Here is the price
before the procedure.

**A local control-layer fork means every future update is a merge.** Not once. Every time, forever,
for as long as the divergence lives. Each update reports your patched files as locally modified,
saves `.local-*` copies, and hands you a three-way reconciliation that nobody on the project will
remember the reasoning for in four months. **Proposing the change upstream is nearly always cheaper,
including when it feels slower today** — upstream costs you one changeset and some waiting; a fork
costs you a merge per release, indefinitely, and the merges get harder as the file drifts.

If, having read that, you still must diverge:

1. **Put the divergence in the domain pack, because that is the mechanism that exists.**
   `.claude/hooks/domain.config.sh` is USER-class: the updater preserves it and never overwrites it,
   and it is the one file under `.claude/` a human owns. Prefer *configuration* over *code* —
   `DOMAIN_NEVER_ESCALATABLE`, `FORBIDDEN_EXEC_TOKENS`, `SECURITY_BOUNDARY_FILES`,
   `BANNED_READ_FILES` and the rest of the pack exist precisely so most divergences never touch a
   harness file at all. **A divergence you can express as a domain pack value is not a fork**, and
   it survives every upgrade for free.

   If it genuinely cannot be expressed as configuration, then you are editing a harness file and the
   updater will classify it as locally modified — which is the billing described in step 3. There is
   no separate escape-hatch file: an earlier draft of this document described a `local-patch.sh`
   sourced by the domain pack, and that mechanism was never built at either end. Do not go looking
   for it.
2. **Record it in `DECISIONS.md` with a name.** Kebab-case, 2–5 words, stating the problem
   (CONTRACT §6): `egress-wall-required-by-policy`, not `local-changes`. The entry carries
   **Default/config.**, **Affected.**, and — this one is the point — *what would have to become true
   upstream for this patch to be deleted.* A fork with no deletion condition is permanent by
   accident.
3. **Expect it in every future update report.** It will appear as a permanent local delta, by name,
   on every `--check` from now on. That recurring line is the feature: it is the fork billing you,
   visibly, every release, which is the only mechanism that reliably gets forks retired.
4. **Never fork the never-escalatable control set to loosen it.** `guard.sh`, `scope-guard.sh`,
   `hooklib.sh`, `escalation-lib.sh`, `approve.sh`, `ratchet.config.sh`, `settings.json`. A local
   patch that makes one of these *stricter* is a defensible decision. A local patch that makes one of
   them *more permissive* has removed the property the whole harness exists to provide, and every
   gate downstream of it is now reporting on a system it no longer describes. If that is what you
   need, uninstall the harness — do not keep a hollow one and let the green checkmarks lie.

---

## 6. Checklist: the first session after an update

Run this before starting any milestone on a freshly-updated harness.

- [ ] **Re-read `.agent-development/ACTIVE-LESSONS.md`.** A scaffold change can obsolete a lesson
      outright — "work around the scope guard's attribution bug" is worse than useless once the bug
      is fixed, and a stale lesson costs tokens in every dispatch for the rest of the project.
      Anything the update fixed gets closed with a `Supersedes:` line, not deleted.
- [ ] **Read the new never-escalatable rules** in the update report, or re-derive them from
      `.claude/hooks/escalation-lib.sh`. Something that used to be approvable with a human
      confirmation may now be a hard wall. A standing workflow that depended on it needs redesigning,
      not approving.
- [ ] **Read the changed configuration defaults** in the report, especially any marked as values this
      project has an opinion about. Nothing fails when a default moves under you; the number is just
      different now, which is the expensive kind of quiet.
- [ ] **Run the hook suite, then the project's own suite.** The updater runs the first one. It cannot
      run the second, and a scaffold change that broke your `VERIFY_CMD` wiring shows up only there.
      ```sh
      python3 .claude/hooks/test_hooks.py
      # then whatever VERIFY_CMD resolves to for this stack
      ```
- [ ] **Re-baseline the control-layer postcondition.** The update changed the suite, so the recorded
      floor of "what this host already fails" is describing a different program. The updater does
      this automatically **only from a green run** — a floor taken from a red suite records today's
      breakage as normal, and the postcondition then passes while the control layer is broken. If the
      suite was not green, fix it, then:
      ```sh
      .claude/hooks/approve.sh --postcondition-baseline
      ```
- [ ] **Resolve every `.local-*` file.** Diff it, decide, then delete it. Deleting it is how the
      `harness-files-locally-modified` row gets closed. A `.local-*` left on disk for a month is a
      decision nobody made.
- [ ] **Close the rows the update filed** in `.agent-development/PENDING-HUMAN-ACTIONS.md`. Set the
      Status column to DONE and say what you did; rows are never deleted, because a closed row is
      evidence.
- [ ] **Commit the update as its own commit.** Nothing else in it. `batched-refinements-self-harm`
      was confirmed twice in the source corpus: one batched control-layer commit broke a closed
      milestone's WIN row and deleted the retro corpus. Scoped commit, suite between, stop at the
      first red.
