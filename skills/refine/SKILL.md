---
name: refine
description: Run your solution past ONE frontier model explicitly chosen by the user, then decide on its review as Primary. Optional Judge and second round run only by direct request. Two modes - optimize (simplify) and audit (hunt errors with evidence). Use when the user says /refine, $refine, "refine this", "audit this solution", "найди ошибки в решении", or asks for a multi-model review pass.
---

# refine — you are PRIMARY

Default pipeline (two models): your solution → user-chosen reviewer → your final.
You rule on its report yourself; there is no judge unless the user asks for one.
`--judge` puts a third model over that report (ACCEPT / MODIFY / REJECT per item),
`--rounds 2` gives another external a second pass. Never add these extras merely
because the task looks important: explain the risk and ask first. On ordinary tasks
they add latency, not value (deliberate default).

The script `refine.py` calls the external CLI(s), keeps the audit trail in
`.llm-audit/<run>/` and records metrics. You do the thinking: solve, revise, finalize.
Never call codex/claude/kimi yourself.

Script: `python3 ~/.agents/skills/refine/refine.py` (call it `REFINE` below).

## Steps

1. **Solve the task first** (or take the solution that already exists in this
   conversation). Do it well; do not pre-shrink it for the sake of minimalism.

2. **Choose the reviewer.** The invocation must name `codex`, `claude`, `kimi`, or
   `qwen`, for example `$refine claude проверь решение`. If the user did not name
   one, ask a single question and stop; never choose or rotate the critic yourself.
   The reviewer must differ from the host model.

3. **Init** — `REFINE init --host <claude|codex|kimi|qwen> --reviewer <user-choice> --slug <2-4-words>`
   (add `--mode audit` when the user asks to *check for errors* rather than to
   *simplify*: "audit this", "найди ошибки", "проверь решение", "adversarial
   review" — then the external model is an Auditor that hunts factual errors,
   false assumptions and missed edge cases with evidence).
   **Two models and one round are the default.** Add `--judge` and/or `--rounds 2`
   only when the user explicitly asks for the larger cycle.
   **Light is the default**: externals are forbidden to read the repo/git/web and
   judge only the inlined primary.md, so the run takes minutes — put ALL facts
   and their sources into primary.md, the reviewer cannot verify anything
   outside it. Add `--full` when the solution is code/repo changes or the
   reviewer must verify claims against files, git history or the web — user
   says "refine full", "полный refine", "глубокий refine", or the deliverable
   is a git diff.
   `--host` is YOUR OWN CLI name (Claude Code → claude, Codex → codex,
   Kimi Code → kimi, Qwen Code → qwen). `--reviewer` is the critic chosen by the
   user. A reserve may replace it only after a recorded quota/failure; this
   substitution must be shown in the result. `REFINE_EXTERNALS` only orders
   reserves. The sole exception is a headless runner that explicitly exports
   `REFINE_AUTOMATED=1`: it may take the first available reviewer from that list.
   A normal user invocation never enables this exception.
   The command prints the run folder `RUN`.

4. **Write two files into RUN:**
   - `task.md` — the user's ORIGINAL request, verbatim (copy the text; no
     paraphrase, no summary). Add relevant constraints the user gave earlier
     in the conversation under a `## Context from the conversation` heading.
   - `primary.md` — your solution: what it is, how it works, key decisions and
     why. For code changes inside a git repo the reviewer reads the repository
     itself (it gets the base commit and runs `git diff`), so describe,
     don't paste the code. For documents / analyses / specs put the full
     deliverable into `primary.md`.

5. **Round 1** — `REFINE round 1` returns immediately (the work runs in the
   background, usually 2–20 minutes). Codex: if it answers
   `refused: running inside the Codex sandbox`, re-run the same command with
   sandbox escalation (request approval to run outside the sandbox). Then wait:
   - Claude Code: run `REFINE wait 1 --timeout 550` with `run_in_background`
     or a Bash timeout ≥ 600 s; re-run while it exits with code 3.
   - Codex / Kimi: run `REFINE wait 1 --timeout 50` in a loop until the exit
     code is 0 (done) or 1 (failed). Never busy-wait with sleep yourself.

6. **Decide** — read `RUN/optimizer-1.md` (the reviewer's report; with `--judge`
   also `RUN/judge-1.md`, and then apply what the Judge marked ACCEPT / MODIFY).
   Without a judge you rule on every item yourself: verify each claim against
   the source before accepting it, and follow the ORIGINAL TASK, not the
   reviewer's taste. You may skip an item only with a stated reason.
   Write the result:
   - single round (default) → `RUN/final.md`;
   - two rounds → `RUN/revision-1.md` now, `RUN/final.md` after round 2.
   First line `Applied: <n>/<m>` (m = items worth applying), then per item what
   you changed or why not, then a short description of the current solution.
   If the report says KEEP AS IS / NO FINDINGS or FAILED, write `Applied: 0/0`
   and a one-line note.

7. **Round 2 (only with `--rounds 2`)** — `REFINE round 2`, then wait as in
   step 5; the other external reviews your revision. If it prints
   `round 2 skipped` (round 1 found nothing), write `final.md` with
   `Applied: 0/0`. Then apply the same way and write `RUN/final.md`.

8. **Finish** — `REFINE finish`. It prints the summary table (calls, latency,
   tokens, verdict counts). Show that table to the user plus 3–6 lines: what
   changed after the review, what you rejected and why, and whether the
   external model failed.

## Rules
- Original task is sacred: the reviewer (and Judge, if any) must see the user's words.
- Evidence beats opinion: a finding is applied only after you confirmed it against
  the source (file, git, log, test). Without a judge this check is entirely on you.
- Do not add complexity while "fixing" a finding; if a simplification breaks a
  requirement, reject it with the reason in final.md.
- If a step of the script fails, read `RUN/calls.log`, report to the user, and
  finish with what you have (`REFINE finish` works after any round).
