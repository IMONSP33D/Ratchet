# UPGRADING.md — Changing the Harness Mid-Project · {{PROJECT_NAME}} · Ratchet

**What this is.** The doctrine for changing the control layer of a project that is already running:
how a human takes a newer Ratchet scaffold without losing this project's work, and — the part that
matters more — what the **agent** does when the pipeline itself is what needs to change.

**Where it lives and who owns it.** `.claude/doctrine/UPGRADING.md`. Harness-owned doctrine, Tier 2b:
it ships with Ratchet, it is identical in every project, and it is replaced wholesale by
`ratchet-update.sh`; if you edit it anyway and upstream has not touched it since, the updater leaves
your edit alone (§2.2 — it is yours now). **Humans: you do not need to edit this file.** Agents MUST
NOT edit it, and no approval lifts that.

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

### 2.2 A real three-way merge, not a diff against your disk

At install and at every update, `install.sh` records `.claude/.ratchet-manifest` (with
`ratchet-update.sh --adopt-baseline` as the one other sanctioned writer, for pre-manifest installs):
two checksums per harness file, as written — one of the file as installed, one of the source
template with every `{{MARKER}}` reduced to a placeholder. That second
hash is what makes a *three*-way compare possible: old-template vs new-template vs on-disk, not just
"does this file match what we last wrote".

Every harness file lands in exactly one of five buckets:

| you edited it | upstream changed it | verdict | what happens |
|---|---|---|---|
| no | no | **SAME** | nothing. |
| no | yes | **UPDATE** | overwritten silently — a clean upgrade. |
| yes | no | **KEEP** | left alone, silently. It is yours now. |
| yes | yes | **CONFLICT** | the only interesting case. Your file is untouched; the new version
  lands beside it as `<file>.ratchet-merge` for you to merge by hand. |
| — | *(no baseline row)* | **UNVERIFIED** | treated as CONFLICT — a difference that cannot be
  attributed is never silently kept or silently overwritten. |

`ratchet-update.sh` decides; `install.sh` writes, same as a first install. Both KEEP and CONFLICT
paths are protected from that write and restored (or merge-filed) immediately after — see the script
header for the exact sequence. A `.claude/.backup-*` directory and a generated `restore.sh` are not
part of this: a CONFLICT file is never overwritten in the first place, so there is nothing to roll
back to, and `git checkout .` remains a complete undo for every UPDATE.

**No manifest at all** (an install that predates the manifest, or a checksum tool that was absent at
install time) → every harness file is UNVERIFIED, i.e. treated as a conflict, until you run
`ratchet-update.sh --adopt-baseline` once — it records the current on-disk tree as the baseline,
writing nothing else. Do this only when you know the tree has not been hand-edited since install:
anything already modified becomes invisible to every future update.

**How a conflict clears.** The unresolved-work marker is the `.ratchet-merge` file itself, not any
manifest state: the report lists every `*.ratchet-merge` still on disk, on every run, until you
merge it into the real file and delete it. (Against the same bundle version, a conflicted file's
*verdict* relaxes to KEEP — it really is just "user-edited" at that point — but the listing keeps
naming it as unresolved as long as the `.ratchet-merge` exists.)

### 2.3 What makes it refuse

| condition | why | override |
|---|---|---|
| `.pipeline/run-active` exists | Swapping the gates mid-run means the run's second half is judged by different rules than its first. | archive the run first (`gc-prune.sh archive <milestone>`) |
| the bundle is an older version | An accidental downgrade silently removes gates you are relying on. | `--allow-downgrade` |
| no checksum tool (no `sha256sum`/`shasum`/`python3`) | "Was this harness file edited?" would become a guess made immediately before overwriting the control layer. | none |
| no terminal and no `--yes` | An unattended process tried to replace the control layer. | `--yes` |

`install.sh` itself still refuses a dirty tracked worktree unconditionally — `ratchet-update.sh`
passes it `--force` on your behalf, because an update to an in-progress project is exactly the
situation `git checkout .` needs to remain a complete undo for, and this updater's whole design is
built around making that true per file instead.

---

## 3. The agent-driven path: why you cannot fix this yourself

If you are an agent reading this mid-run because a gate is wrong: **you may not edit the control
layer.** `.claude/**` is Tier 2b and every refusal on it is FINAL (CONTRACT §5.6). There is no
approval channel to appeal to — it was removed 2026-08-24 precisely because a wall you can knock on
is not a wall.

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

**A local control-layer fork means every future update THAT TOUCHES THE SAME FILE is a merge.** Not
every update — the three-way compare (§2.2) leaves a fork alone, silently, for as long as upstream
does not touch that file too. But the day upstream *does* change it, your fork and upstream's change
collide by construction: CONFLICT, a `.ratchet-merge` to reconcile by hand, and nobody on the project
will remember the original reasoning four months later. **Proposing the change upstream is nearly
always cheaper, including when it feels slower today** — upstream costs you one changeset and some
waiting; a fork costs you an unpredictable merge, on an unpredictable release, for as long as the
divergence lives, and the merge gets harder as the file drifts on both sides in the meantime.

If, having read that, you still must diverge:

1. **Put the divergence in the domain pack, because that is the mechanism that exists.**
   `.claude/hooks/domain.config.sh` is USER-class: the updater preserves it and never overwrites it,
   and it is the one file under `.claude/` a human owns. Prefer *configuration* over *code* —
   `FORBIDDEN_EXEC_TOKENS`,
   `BANNED_READ_FILES` and the rest of the pack exist precisely so most divergences never touch a
   harness file at all. **A divergence you can express as a domain pack value is not a fork**, and
   it survives every upgrade for free.

   If it genuinely cannot be expressed as configuration, then you are editing a harness file and the
   updater will classify it as KEEP (§2.2) — silent until upstream changes the same file, then
   CONFLICT. There is no separate escape-hatch file: an earlier draft of this document described a
   `local-patch.sh` sourced by the domain pack, and that mechanism was never built at either end. Do
   not go looking for it.
2. **Record it in `DECISIONS.md` with a name.** Kebab-case, 2–5 words, stating the problem
   (CONTRACT §6): `egress-wall-required-by-policy`, not `local-changes`. The entry carries
   **Default/config.**, **Affected.**, and — this one is the point — *what would have to become true
   upstream for this patch to be deleted.* A fork with no deletion condition is permanent by
   accident.
3. **Expect the bill on whichever update collides with it.** Not every `--check` — only the one where
   upstream touches the same file, which is exactly when a merge is actually needed. That CONFLICT
   line, when it arrives, is the fork billing you: it is the mechanism that reliably gets forks
   retired instead of drifting unnoticed.
4. **Never fork the control set to loosen it.** `guard.sh`, `scope-guard.sh`, `hooklib.sh`,
   `ratchet.config.sh`, `settings.json`. A local
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
- [ ] **Diff `.claude/hooks/ratchet.config.sh`'s defaults the same way**, especially any this project
      overrides via `settings.json` `.env` or `domain.config.sh`. Nothing fails when a default moves
      under you; the number is just different now, which is the expensive kind of quiet.
- [ ] **Run the hook suite, then the project's own suite.** The updater runs the first one. It cannot
      run the second, and a scaffold change that broke your `VERIFY_CMD` wiring shows up only there.
      ```sh
      python3 .claude/hooks/test_hooks.py
      # then whatever VERIFY_CMD resolves to for this stack
      ```
- [ ] **Resolve every `<file>.ratchet-merge`.** It sits beside a file the updater left untouched
      because you had edited it AND upstream changed it too (§2.2, CONFLICT). Diff the two, merge by
      hand into the real file, then delete the `.ratchet-merge` — until you do, every future
      update's report lists it under UNRESOLVED, which is deliberate, not a bug.
- [ ] **Close the rows the update filed** in `.agent-development/PENDING-HUMAN-ACTIONS.md`. Set the
      Status column to DONE and say what you did; rows are never deleted, because a closed row is
      evidence.
- [ ] **Commit the update as its own commit.** Nothing else in it. `batched-refinements-self-harm`
      was confirmed twice in the source corpus: one batched control-layer commit broke a closed
      milestone's WIN row and deleted the retro corpus. Scoped commit, suite between, stop at the
      first red.
