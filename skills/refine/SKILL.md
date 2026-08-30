---
name: refine
description: Run your solution through two other frontier models (second model → Judge, two rounds with swapped roles). Two modes - optimize (Optimizer simplifies without losing quality) and audit (adversarial Auditor hunts errors, false assumptions, missed edge cases with evidence). You stay the author (Primary). Use when the user says /refine, $refine, "refine this", "audit this solution", "найди ошибки в решении", "прогони через refine", "упрости решение через другие модели", or asks for a multi-model review pass.
---

# refine — you are PRIMARY

Pipeline: your solution → Optimizer (model A) → Judge (model B) → your revision →
Optimizer (B) → Judge (A) → your final. The script `refine.py` calls the two other
CLIs, keeps the audit trail in `.llm-audit/<run>/` and records metrics. You do the
thinking: solve, revise, finalize. Never call codex/claude/kimi yourself.

Script: `python3 ~/.agents/skills/refine/refine.py` (call it `REFINE` below).

## Steps

1. **Solve the task first** (or take the solution that already exists in this
   conversation). Do it well; do not pre-shrink it for the sake of minimalism.

2. **Init** — `REFINE init --host <claude|codex|kimi> --slug <2-4-words>`
   (add `--mode audit` when the user asks to *check for errors* rather than to
   *simplify*: "audit this", "найди ошибки", "проверь решение", "adversarial
   review" — then the second model is an Auditor that hunts factual errors, false
   assumptions, missed edge cases with evidence, and the Judge rules each finding
   valid/partly/invalid; `--rounds 1` for a single pass).
   `--host` is YOUR OWN CLI name (Claude Code → claude, Codex → codex,
   Kimi Code → kimi, Qwen Code → qwen). The two other roles and a reserve CLI
   (steps in on a quota/rate-limit error) are picked automatically from the
   remaining three. The command prints the run folder `RUN`.

3. **Write two files into RUN:**
   - `task.md` — the user's ORIGINAL request, verbatim (copy the text; no
     paraphrase, no summary). Add relevant constraints the user gave earlier
     in the conversation under a `## Context from the conversation` heading.
   - `primary.md` — your solution: what it is, how it works, key decisions and
     why. For code changes inside a git repo the reviewers read the repository
     themselves (they get the base commit and run `git diff`), so describe,
     don't paste the code. For documents / analyses / specs put the full
     deliverable into `primary.md`.

4. **Round 1** — `REFINE round 1` returns immediately (the work runs in the
   background: Optimizer then Judge, usually 2–20 minutes). Codex: if it answers
   `refused: running inside the Codex sandbox`, re-run the same command with
   sandbox escalation (request approval to run outside the sandbox). Then wait:
   - Claude Code: run `REFINE wait 1 --timeout 550` with `run_in_background`
     or a Bash timeout ≥ 600 s; re-run while it exits with code 3.
   - Codex / Kimi: run `REFINE wait 1 --timeout 50` in a loop until the exit
     code is 0 (done) or 1 (failed). Never busy-wait with sleep yourself.

5. **Revision 1** — read `RUN/judge-1.md` (and `optimizer-1.md`). Apply what
   the Judge marked ACCEPT / MODIFY, following the ORIGINAL TASK, not the
   Optimizer's taste. You may skip an item only with a stated reason. Then write
   `RUN/revision-1.md`: first line `Applied: <n>/<m>` (m = proposals judged
   ACCEPT+MODIFY), then per item what you changed or why not, then a short
   description of the current solution. If `judge-1.md` says SKIPPED (Optimizer
   returned KEEP AS IS) or FAILED, write `Applied: 0/0` and a one-line note.

6. **Round 2** — `REFINE round 2`, then wait exactly as in step 4. Roles are
   swapped automatically. If it prints `round 2 skipped` (round 1 was KEEP AS IS /
   NO FINDINGS), write `final.md` with `Applied: 0/0` and go to step 8. (If the
   run was started with `init --rounds 1`, skip this step: after round 1 write
   `final.md` instead of `revision-1.md` and finish.)

7. **Final** — read `RUN/judge-2.md`, apply the same way, write `RUN/final.md`
   (`Applied: n/m` first line, then the final solution description). If round 2
   FAILED, the final is revision 1: say so in `final.md`.

8. **Finish** — `REFINE finish`. It prints the summary table (calls, latency,
   tokens, verdict counts). Show that table to the user plus 3–6 lines: what got
   simpler after round 1, after round 2, what you rejected and why, and which
   external model (if any) failed.

## Rules
- Original task is sacred: Optimizer and Judge must see the user's words.
- Evidence beats opinion: if a Judge verdict says UNRESOLVED and names a test or
  check, run it yourself before deciding.
- Do not add complexity while "fixing" a verdict; if a simplification breaks a
  requirement, reject it with the reason in revision/final.
- If a step of the script fails, read `RUN/calls.log`, report to the user, and
  finish with what you have (`REFINE finish` works after any round).
