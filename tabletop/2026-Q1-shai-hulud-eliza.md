# Tabletop exercise: `eliza-allora-plugin` poisoned publish

**Scheduled for:** TBD — first available 90-minute slot in 2026 Q1.
Facilitator (a DevOps engineer who is **not** the current on-call —
typically the runbook author or last quarter's facilitator) schedules
and announces in `#security-alerts` at least 2 weeks before. The
incident-lead role belongs to whichever DevOps engineer is on-call
at exercise start time, which must not be the same person as the
facilitator.
**Duration:** 90 minutes (60 min exercise + 30 min debrief).
**Stakes:** zero production impact — pure simulation in a Slack channel.
**Reference:** [`SECURITY-RUNBOOK.md`](../SECURITY-RUNBOOK.md) is the
script every participant runs against.

---

## 1. Pre-exercise setup (facilitator, day-of)

- [ ] Confirm attendance per [§3 Roles](#3-roles-pre-assigned).
- [ ] Spin up an isolated Slack channel `#tabletop-2026-q1` (invite-only).
- [ ] Pin this document to the channel.
- [ ] Have a stopwatch ready for the time-to-clean-republish target (<30 min).
- [ ] Have the runbook open in a second tab — participants will reference
  it live, so you should be watching which sections they navigate to and
  how fast they find what they need.
- [ ] Reserve `+1` slot for the founder on-call to silently observe.

---

## 2. The injected scenario

> **04:00 PM yesterday** (relative to exercise start time), a release
> workflow run on `allora-network/eliza-allora-plugin` published
> `eliza-allora-plugin@<latest>` to npm. The published tarball contains a
> `postinstall` script that:
>
> 1. Reads `~/.npmrc` and exfils any `_authToken` to a CloudFlare worker
>    at `https://eliza-telemetry.workers.dev/intake`.
> 2. Mines local `.git/config` for credentials helpers (macOS keychain,
>    libsecret) and exfils what it finds.
> 3. Republishes itself with a new bumped version (`<latest>.1`)
>    containing the same payload, using the exfilled `_authToken`.
>
> **06:30 PM yesterday**, Socket's advisory feed flagged
> `eliza-allora-plugin@<latest>` and `@<latest>.1` as compromised.
>
> **08:00 AM today** (exercise start), the org-wide IOC sweep workflow
> (DEVOP-560) opened
> `allora-network/incident-response#<num>` and the daily-sweep Slack
> bot posted in `#security-alerts`. **You are arriving at your laptop
> with a coffee and seeing the alert for the first time. Go.**

The facilitator pastes the alert in `#tabletop-2026-q1` at T+0. The
exercise clock starts when the first participant types `ack`.

---

## 3. Roles (pre-assigned)

| Role | Assigned to | What they do during the exercise |
|---|---|---|
| **Facilitator** | A DevOps engineer who is **not** the current on-call (runbook author or previous facilitator) | Runs the exercise from outside the in-character roster. Pastes the injected scenario, holds the stopwatch, watches for failure modes, runs the debrief. Never plays the lead — that defeats the test. |
| **Incident lead** | The DevOps engineer on-call **at exercise start time** (not the facilitator) | Calls the shots. Reads the runbook. Decides when to escalate. They are responsible for the timeline. |
| **Communicator** | A different DevOps engineer | Owns external comms — drafts the GitHub security advisory, the downstream-consumer email, the Slack updates. Does NOT execute commands. |
| **Executor** | A third DevOps engineer | Runs every `gh`, `npm`, `kubectl`, and `cosign` command the lead asks for. Pastes output back to the channel. Does NOT make decisions; if the lead's instruction is ambiguous, asks. |
| **Backend rep** | One backend engineer | Represents the consumer-of-this-package perspective. When the communicator drafts the downstream notification, the backend rep reads it as if it landed in their inbox and pushes back on anything unclear. |
| **Frontend rep** | One frontend engineer | Same, but for the frontend-side dependency story. (`eliza-allora-plugin` is a dev-tool; both BE and FE consume.) |
| **Founder observer** | One of the founders | Silent observer. Their only job is to confirm the team can run this without exec involvement during a real incident, so they DO NOT participate in decisions, commentary, or approvals. (The runbook's destructive-action gate — full-package unpublish/delete, runbook §5 step 1 — requires "publisher and on-call agree, in writing, in `#security-alerts`," not founder approval; the founder observer is therefore not in the authority chain for any phase of this exercise.) They take notes for the debrief. |

If someone is missing on the day, **postpone**. Skipping a role to run
the exercise on schedule defeats the purpose; reschedule rather than
half-run it.

---

## 4. Phases (and what success looks like)

Each phase is timed against the [SECURITY-RUNBOOK](../SECURITY-RUNBOOK.md)
section it exercises. The facilitator notes elapsed time as participants
move into each phase. The 30-minute target covers Phases 1–4; Phases 5
and 6 happen after the clock stops.

**Wall-clock layout:**

```
T+0           Exercise clock starts on first `ack`.
T+30          Clock stops at end of Phase 4 (clean-republish target).
T+30 → T+60   Debrief (§5). Phase 5 token-rotation walk runs in
              parallel with the debrief and concludes whenever the
              rotation list is exhausted.
after T+60    Phase 6 post-mortem draft, once Phase 5 is done.
```

**Sim-vs-real rule (every phase).** Read-only commands — `gh search`,
`gh api`, `kubectl get`, reading workflow YAML, listing secrets — are
run for real against live infrastructure. Anything that would mutate
state — `npm publish`, `npm deprecate`, `npm unpublish`, the actual
GHA release run, sending the advisory or the consumer notification —
is pasted in chat as the executor would type it but **not executed**.
The exercise is a Slack-channel walkthrough, not a live production
action. If you are unsure whether a command is sim or real, default
to sim and ask in channel.

### Phase 1 — Detection + triage (target: T+5 min)

Runbook §1–2.

- [ ] Lead acks the alert in `#tabletop-2026-q1` (this is the `ack`
  that starts the clock for everyone else).
- [ ] Lead walks the triage decision tree out loud, narrating each
  decision point. ("IOC match → did we publish? → yes → Scenario C.")
- [ ] Communicator opens a fresh Slack thread for the running timeline.

**Success:** the team reaches "this is Scenario C" within 5 minutes of
T+0 without anyone opening a file outside the runbook.

**Failure modes the facilitator should be watching for:**
- Lead skipping the IOC-list cross-check before assuming the worst.
- Executor running commands ahead of the lead asking for them.
- Communicator drafting external comms before triage is complete.

### Phase 2 — Stop the bleed (target: T+10 min)

Runbook §5 step 1.

- [ ] Lead instructs executor to deprecate the published versions on
  npm. Executor types the exact `npm deprecate` invocation; lead
  confirms before executor "runs" it. (Per the §4 sim-vs-real rule
  this is a state-changing command — pasted only, not executed.)
- [ ] Lead decides whether to attempt `npm unpublish` of the bad
  versions (within the 72-hour window). This is a per-version
  unpublish, which the lead owns directly — no separate authorization
  is required. (Full-package deletion is a separate, forbidden action
  per runbook §5 step 1; if anyone reaches for it, the executor must
  decline until "publisher and on-call agree, in writing, in
  `#security-alerts`" is captured in channel — and that gate must
  not fire in this exercise.)
**Success:** within 10 minutes, both bad versions are deprecated and
the per-version `npm unpublish` decision (yes/no) has been made and
announced in channel by the lead. The lead owns this call; no
separate authorization is required. The runbook's destructive-action
gate (publisher + on-call written agreement) applies only to
full-package deletion, which this scenario forbids.

**Failure mode:** the team tries to *delete* the package entirely
rather than deprecate-and-unpublish. The runbook explicitly forbids
this; if it happens, that's a runbook-violation note for the debrief.

### Phase 3 — Audit blast radius (target: T+20 min)

Runbook §5 step 3 + cross-reference with runbook §4 (the publish
workflow IS a CI runner that ran the bad code, so we exercise both
scenarios here).

- [ ] Executor lists every secret the publish workflow could have
  read. Communicator drafts the rotation tickets.
- [ ] Executor `gh search`es for every consumer repo (`package.json`
  dependencies and `Dockerfile` references) and lists which Harbor /
  ECR registry repos contain images built from this package. Lead
  decides which consumer repos need pin PRs filed, which images need
  rebuild tickets, and which can wait for the daily sweep to surface
  them.
- [ ] Communicator drafts the GitHub security advisory (paste the
  draft into chat for review).
- [ ] Communicator drafts the downstream-consumer notification.
  Backend + frontend reps read the draft critically — the only
  required input from them at this point is "as a recipient of this
  notification, would I know what to do?"

**Success:** within 20 minutes, the rotation list is complete, the
consumer-repo PR list is decided, and both the advisory and the
notification are drafted (not sent — just drafted for review).

**Failure mode:** the team starts rotating tokens before listing
them. List, then rotate; otherwise you'll miss one.

### Phase 4 — Clean republish (target: T+30 min)

Runbook §5 steps 4–7.

- [ ] Lead picks the clean environment: a fresh GHA-hosted runner
  (the regular release workflow will do, since DEVOP-545 fixed the
  token-before-install ordering). Lead does NOT use a local machine.
- [ ] Executor describes the steps the release workflow takes (read
  the actual workflow YAML from `eliza-allora-plugin`'s release.yml
  out loud, confirm the post-DEVOP-545 ordering is in place).
- [ ] Lead cuts a fresh minor bump tag — describes the tag name and
  the workflow that will fire.
- [ ] Executor "monitors" the workflow run; calls out each step
  completing.
- [ ] Communicator sends the advisory and the consumer notification.

**Success:** within 30 minutes of T+0, a clean version is "published"
and the advisory + notification are out.

**Failure modes:**
- Lead tries to republish from a local machine because it's "faster" —
  this is the worst failure mode of this exercise. Lead must reach for
  the cleanest available environment regardless of clock pressure.
- Lead reuses the bad version number (npm + PyPI both block this; the
  test is whether the team remembers without being told).

### Phase 5 — Token rotation (clock stops at end of Phase 4; this runs in parallel and concludes after debrief)

Runbook §7.

- [ ] Lead walks the rotation list. Each token in the blast radius from
  Phase 3 gets a checkmark or a follow-up ticket.
- [ ] Communicator notes which tokens are migratable to OIDC Trusted
  Publishers (npm + PyPI) — files DEVOP-578 follow-up if not already.

### Phase 6 — Post-mortem (after Phase 5)

Runbook §1 close-out + general post-mortem template.

- [ ] Lead drafts the post-mortem template:
  - Timeline (from this exercise — paste the channel transcript).
  - Root cause: the original `eliza-allora-plugin` publish workflow
    had `NPM_TOKEN` written before install (or had `ignore-scripts`
    not enforced, or had no Trusted Publisher migration done).
    Whichever — pick what's plausibly still true given current state.
  - Detection-to-mitigation timeline (T+0 was the daily sweep, but
    the actual exfil started 16 hours earlier when the bad version
    was published — that 16-hour blind spot is the most important
    finding).
  - Action items: file each gap as a Linear ticket.

---

## 5. Debrief (30 minutes after clock stops)

Facilitator runs through these questions in order. Take notes
verbatim; the team's words are the ticket descriptions.

1. **What was slow that should have been fast?** Anything that made
   the team navigate the runbook for more than 30 seconds without
   finding what they needed. → runbook-update ticket(s).
2. **What was ambiguous?** Any step where the lead and executor had
   to negotiate what was meant. → runbook-clarification ticket(s).
3. **What was missing?** Any step the team had to improvise because
   the runbook didn't cover it. → runbook-expansion ticket(s).
4. **What was overkill?** Any step the team skipped because it
   seemed obviously not applicable to this scenario. Note for the
   next runbook revision — sometimes the answer is "delete the
   step," sometimes it's "the step is right, the scenario didn't
   exercise it, that's fine."
5. **Did we hit the 30-minute target?** If yes, by how much margin?
   If no, where did we lose the time?
6. **Who's running next year's exercise?** Rotate facilitation.

---

## 6. Outputs

Within 48 hours of the exercise, the facilitator files:

- [ ] One Linear ticket per item from the debrief in the `Shai-Hulud
  Mitigation` project (or its successor by 2026 Q1).
- [ ] A PR on this file (`tabletop/2026-Q1-shai-hulud-eliza.md`)
  updating the "Lessons learned" section below.
- [ ] A PR on `SECURITY-RUNBOOK.md` with whatever runbook deltas
  came out of the exercise.
- [ ] A calendar invite for the 2027 Q1 exercise.

---

## 7. Lessons learned

(Filled in after the exercise runs. Empty for now.)

- _TBD — first exercise hasn't happened yet._

---

## 8. Notes from the runbook author (DEVOP-571 author, for the facilitator)

Things I'd specifically watch for during the run, since I wrote the
runbook and have opinions about where the seams are:

- **§5 Scenario C step 1** is the most decision-dense moment. The
  npm deprecate vs. unpublish vs. delete decision is the one place
  the runbook constrains authority — per-version `npm unpublish` is
  the lead's call (no extra gate); full-package deletion is gated on
  "publisher and on-call agree, in writing, in `#security-alerts`"
  and is forbidden in this scenario. Watch whether the team
  articulates that gate correctly or routes around it.
- **§7 Token rotation** is long. Watch whether the team
  systematically walks the table or skips around. Skipping leads to
  missed rotations; that's a known failure mode.
- **§9 Appendix command snippets** were written to be copy-paste-
  runnable. If anyone has to modify a snippet by hand to get it to
  work, that's a runbook-update ticket — note the exact modification.
- The runbook's "Stop the bleed → Audit blast radius → Restore
  service → Close-out" rhythm is the most opinionated structural
  choice. Watch whether participants use that vocabulary or
  default to ad-hoc language. Adoption of the rhythm is the test.
- **Cross-registry muscle memory.** This scenario is npm-only.
  The runbook §5 covers PyPI yank steps as well; if anyone
  reflexively reaches for the PyPI workflow during this exercise,
  log it as a runbook-clarification ticket about scenario scoping.

---

**Document status (2026-05-13):** scenario authored as part of DEVOP-573
in advance of the runbook (DEVOP-571) merging. The exercise itself is a
team activity and is **NOT** considered complete until the run + debrief
have actually happened. The DEVOP-573 ticket should stay in `In Review`
status until the facilitator schedules and runs the live session.
