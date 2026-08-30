#!/usr/bin/env python3
"""refine — Primary → Optimizer → Judge, two rounds, three CLIs (codex / claude / kimi).

The host session is Primary. This script only calls the two *other* CLIs in
read-only mode (Codex: OS sandbox; Claude: tool allowlist; Kimi: agent profile without
Write/Edit — Bash restricted by prompt only, no OS sandbox), keeps the audit trail in .llm-audit/<run>/ and records metrics in
meta.json. Commands: init | round N | wait N | status | finish   (see README.md).
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
AUDIT = Path(os.environ.get("REFINE_AUDIT_DIR", ".llm-audit"))
TIMEOUT = int(os.environ.get("REFINE_TIMEOUT", "1200"))  # seconds per external call
JUDGE_TIMEOUT = int(os.environ.get("REFINE_JUDGE_TIMEOUT", "600"))  # judge cap; a timeout hands the role to the reserve
MAX_PROMPT = 600_000  # chars; kimi takes the prompt via argv (ARG_MAX 1 MB on macOS)
CLIS = ["codex", "claude", "kimi", "qwen"]
# externals = the three CLIs that are not the host: round 1 = (e0 → e1), round 2 = (e1 → e0), e2 = reserve
# (steps in when a call hits a quota/rate limit or fails twice). REFINE_EXTERNALS="a,b,c" overrides the order.
QUOTA_RE = re.compile(r"rate.?limit|usage limit|quota|too many requests|\b429\b|insufficient (credit|balance)|"
                      r"limit (reached|exceeded)|capacity|overloaded|exhausted", re.I)
MODELS = json.loads((HERE / "models.json").read_text()) if (HERE / "models.json").exists() else {}
SOLUTION_FILE = {1: "primary", 2: "revision-1"}


# ---------- small helpers ----------
def now():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def git(*args):
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def read(path):
    return path.read_text() if path.exists() else ""


def log(run, msg):
    with open(run / "calls.log", "a") as f:
        f.write(f"{now()} {msg}\n")


def meta_load(run):
    return json.loads((run / "meta.json").read_text())


def meta_save(run, meta):
    (run / "meta.json").write_text(json.dumps(meta, indent=1, ensure_ascii=False))


def set_status(run, n, state, note=""):
    (run / f"round-{n}.status").write_text(json.dumps({"state": state, "note": note, "updated": now()}))


def get_status(run, n):
    p = run / f"round-{n}.status"
    return json.loads(p.read_text()) if p.exists() else None


def run_dir(arg):
    if arg:
        return Path(arg)
    latest = AUDIT / "latest"
    if latest.is_symlink():
        return AUDIT / os.readlink(latest)
    sys.exit("no run found: run `refine.py init` first (or pass --run DIR)")


def detect_host():
    if os.environ.get("CODEX_THREAD_ID"):
        return "codex"
    if os.environ.get("CLAUDECODE"):
        return "claude"
    sys.exit("cannot detect host CLI: pass --host claude|codex|kimi|qwen")


def config_model(cli):
    """Best-effort: the model the CLI will use by default (read from its config, model line only)."""
    env = os.environ.get(f"REFINE_MODEL_{cli.upper()}") or MODELS.get(cli)
    if env:
        return env
    files = {"codex": Path.home() / ".codex/config.toml", "kimi": Path.home() / ".kimi-code/config.toml"}
    key = {"codex": "model", "kimi": "default_model"}
    if cli in files and files[cli].exists():
        m = re.search(rf'^{key[cli]}\s*=\s*"([^"]+)"', files[cli].read_text(), re.M)
        if m:
            return m.group(1)
    return None


def clean_env():
    """Externals must not inherit the host's session markers (nested detection, nested-session guards)."""
    return {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "CODEX_", "KIMI_"))}


def snapshot(run, name, meta):
    """git diff against the base commit + untracked files → <name>.diff (empty diff → no file)."""
    base = meta.get("base_sha")
    if not base:
        return
    diff = git("diff", base, "--", ".", f":(exclude){AUDIT}")
    for p in git("ls-files", "--others", "--exclude-standard").split("\n"):
        if not p or p.startswith(str(AUDIT)):
            continue
        try:
            diff += f"\n--- new file: {p} ---\n{Path(p).read_text()[:30_000]}\n"
        except (OSError, UnicodeDecodeError):
            continue  # binary / unreadable: not part of a reviewable solution
    if diff.strip():
        (run / f"{name}.diff").write_text(diff)


# ---------- prompt ----------
def section(title, body):
    return f"=== {title} ===\n{body.strip()}\n=== END {title.split(' (')[0]} ==="


def build_prompt(run, meta, role, n, cli=None):
    sol = SOLUTION_FILE[n]
    mode = meta.get("mode", "optimize")
    cli = cli or meta["rounds"][str(n)][role]
    role_file = "auditor.md" if (role == "optimizer" and mode == "audit") else f"{role}.md"
    parts = [read(HERE / role_file),
             f"ROUND: {n} of {len(meta['rounds'])}. Your CLI: {cli}. MODE: {mode}"
             + (" — the second model is an adversarial AUDITOR (finds errors, not simplifications): judge each "
                "finding A1.. as ACCEPT = valid, must fix / MODIFY = partly valid, narrow it / REJECT = invalid."
                if (mode == "audit" and role == "judge") else ""),
             section("ORIGINAL TASK (verbatim from the user)", read(run / "task.md")),
             section(f"CURRENT SOLUTION ({sol}.md, written by Primary)", read(run / f"{sol}.md"))]
    if n == 2:  # round 2 must see the full deliverable, not only the revision changelog
        parts.append(section("ROUND 1 SOLUTION (primary.md — full original deliverable)", read(run / "primary.md")))
        parts.append(section("ROUND 1 HISTORY (Judge verdicts already applied by Primary)", read(run / "judge-1.md")))
    if role == "judge":
        parts.append(section("AUDITOR REPORT" if mode == "audit" else "OPTIMIZER REPORT", read(run / f"optimizer-{n}.md")))
    base = (f"Base commit: {meta['base_sha']} — review the code changes yourself with `git diff {meta['base_sha']}` "
            f"and `git status --short` (untracked files are part of the solution too).\n") if meta.get("base_sha") else ""
    if cli == "qwen" and read(run / f"{sol}.diff"):  # qwen -p has no shell: give it the diff snapshot inline
        parts.append(section("CODE CHANGES (git diff snapshot — you have no shell, read files with your file tools)",
                             read(run / f"{sol}.diff")[:150_000]))
        base = "Code changes are inlined above; verify against the files with your read tools.\n"
    parts.append(section("ENVIRONMENT",
                         f"Working directory: {meta['cwd']} — you have read-only access; verify claims against "
                         f"its files, git history and docs before asserting them.\n{base}"
                         f"Audit folder of this run: {run.resolve()}\n"
                         f"Write your answer as plain markdown to stdout only. Do not modify any files."))
    prompt = "\n\n".join(parts)
    if len(prompt) > MAX_PROMPT:
        raise RuntimeError(f"prompt too large ({len(prompt)} chars > {MAX_PROMPT}); shorten the solution text")
    return prompt


# ---------- external CLIs (all read-only) ----------
def call_codex(prompt, run, timeout=TIMEOUT):
    out = run / ".codex-last.md"
    cmd = ["codex", "exec", "--json", "--ephemeral", "-s", "read-only", "-C", os.getcwd(),
           "--skip-git-repo-check", "-o", str(out)]
    if os.environ.get("REFINE_MODEL_CODEX"):
        cmd += ["-m", os.environ["REFINE_MODEL_CODEX"]]
    cmd.append("-")
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=timeout, env=clean_env())
    usage, text, err = None, "", ""
    for line in p.stdout.splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("type") == "turn.completed":
            usage = e.get("usage")
        elif e.get("type") == "turn.failed":
            err = str(e.get("error"))
        elif e.get("type") == "item.completed" and e.get("item", {}).get("type") == "agent_message":
            text = e["item"].get("text", "")
    if out.exists():
        text = out.read_text() or text
        out.unlink()
    return text, {"rc": p.returncode, "usage": usage, "cost_usd": None, "model": config_model("codex"),
                  "error": err or None, "stderr": p.stderr[-3000:]}


def call_claude(prompt, run, timeout=TIMEOUT):
    cmd = ["claude", "-p", "--output-format", "json", "--setting-sources", "", "--no-session-persistence",
           "--strict-mcp-config", "--permission-mode", "dontAsk", "--tools", "Read,Glob,Grep,Bash",
           "--allowedTools", "Read,Glob,Grep,Bash(git diff *),Bash(git log *),Bash(git show *),"
                             "Bash(git status *),Bash(git ls-files *),Bash(git blame *)"]
    if os.environ.get("REFINE_MODEL_CLAUDE"):
        cmd += ["--model", os.environ["REFINE_MODEL_CLAUDE"]]
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=timeout, env=clean_env())
    try:
        arr = json.loads(p.stdout)
        res, init = arr[-1], arr[0]
    except (json.JSONDecodeError, IndexError, TypeError):
        return p.stdout, {"rc": p.returncode or 1, "error": "malformed json output", "stderr": p.stderr[-3000:]}
    rc = 1 if res.get("is_error") else p.returncode
    return res.get("result", ""), {"rc": rc, "usage": res.get("usage"), "cost_usd": res.get("total_cost_usd"),
                                   "model": init.get("model"), "error": res.get("result") if rc else None,
                                   "stderr": p.stderr[-3000:]}


def call_kimi(prompt, run, timeout=TIMEOUT):
    cmd = ["kimi", "-p", prompt, "--output-format", "stream-json", "--agent-file", str(HERE / "kimi-agent.md")]
    if os.environ.get("REFINE_MODEL_KIMI"):
        cmd += ["-m", os.environ["REFINE_MODEL_KIMI"]]
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, env=clean_env())
    msgs, after_tool = [], 0
    for line in p.stdout.splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("role") == "assistant" and isinstance(e.get("content"), str) and e["content"].strip():
            msgs.append(e["content"])
        elif e.get("role") == "tool":
            after_tool = len(msgs)
    text = "\n\n".join(msgs[after_tool:] or msgs)  # the answer is what comes after the last tool result
    return text, {"rc": p.returncode, "usage": None, "cost_usd": None, "model": config_model("kimi"),
                  "error": None, "stderr": p.stderr[-3000:]}


def call_qwen(prompt, run, timeout=TIMEOUT):
    """qwen -p: read-only by construction (no shell / write tools in prompt mode — verified 30.08.2026)."""
    cmd = ["qwen", "-p", "Follow the instructions above exactly.", "--output-format", "json"]
    model = config_model("qwen")
    if model:
        cmd += ["-m", model]
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=timeout, env=clean_env())
    try:
        arr = json.loads(p.stdout)
        res, init = arr[-1], arr[0]
    except (json.JSONDecodeError, IndexError, TypeError):
        return p.stdout, {"rc": p.returncode or 1, "error": "malformed json output", "stderr": p.stderr[-3000:]}
    rc = 1 if res.get("is_error") else p.returncode
    return res.get("result", ""), {"rc": rc, "usage": res.get("usage"), "cost_usd": None,
                                   "model": init.get("model") or model, "error": res.get("result") if rc else None,
                                   "stderr": p.stderr[-3000:]}


CALLERS = {"codex": call_codex, "claude": call_claude, "kimi": call_kimi, "qwen": call_qwen}


def call(cli, role, n, prompt, run, meta):
    """External call: up to 2 attempts on `cli`; a quota/rate-limit error skips the retry. If both fail (or quota),
    the reserve CLI (meta['reserve']) takes the role with its own prompt. Every attempt is recorded in meta."""
    reserve = meta.get("reserve")
    plan = [(cli, 1), (cli, 2)] + ([(reserve, 1)] if reserve and reserve != cli else [])
    timeout = JUDGE_TIMEOUT if role == "judge" else TIMEOUT
    quota_hit = False
    for cur, attempt in plan:
        if cur == cli and attempt == 2 and quota_hit:
            continue  # no point retrying a quota-limited CLI
        if cur != cli:
            prompt = build_prompt(run, meta, role, n, cli=cur)
            log(run, f"{role}-{n}: {cli} unavailable ({'quota/timeout/not found' if quota_hit else 'failed twice'}) → reserve {cur}")
        rec = {"round": n, "role": role, "cli": cur, "attempt": attempt, "started": now(), "prompt_chars": len(prompt)}
        if cur != cli:
            rec["substituted_for"] = cli
        set_status(run, n, "running", f"{role}: {cur} (attempt {attempt})")
        t0 = time.time()
        try:
            if cur not in CALLERS:
                raise FileNotFoundError(cur)
            text, info = CALLERS[cur](prompt, run, timeout)
        except subprocess.TimeoutExpired:
            text, info = "", {"rc": None, "error": f"timeout after {timeout}s", "timeout": True}
            if cur == cli:
                quota_hit = True  # a model that timed out will time out again: straight to the reserve
        except FileNotFoundError:
            text, info = "", {"rc": None, "error": f"`{cur}` not found in PATH"}
        except RuntimeError as e:
            text, info = "", {"rc": None, "error": str(e)}
        stderr = info.pop("stderr", "")
        rec.update(info)
        rec["latency_s"] = round(time.time() - t0, 1)
        rec["output_chars"] = len(text or "")
        rec["ok"] = bool((text or "").strip()) and info.get("rc") == 0
        if not rec["ok"] and QUOTA_RE.search(f"{info.get('error') or ''} {stderr} {text or ''}"):
            rec["quota"] = True
            if cur == cli:
                quota_hit = True
        meta["calls"].append(rec)
        meta_save(run, meta)
        log(run, f"{role}-{n} {cur} attempt {attempt}: rc={info.get('rc')} ok={rec['ok']} quota={rec.get('quota', False)} "
                 f"{rec['latency_s']}s error={info.get('error')}" + ("" if rec["ok"] else f"\n{stderr}".rstrip()))
        if rec["ok"]:
            if cur != cli:  # the reserve did the job: record it as the role's CLI for this round
                meta["rounds"][str(n)][role] = cur
                meta["rounds"][str(n)][f"{role}_original"] = cli
                meta_save(run, meta)
            return text
        if str(info.get("error", "")).endswith("not found in PATH") and cur == cli:
            quota_hit = True  # treat as unavailable: go straight to the reserve
    return None


# ---------- parsing ----------
def parse_round(opt_text, judge_text):
    keep = bool(re.match(r"\s*(KEEP AS IS|NO FINDINGS)", opt_text or ""))
    r = {"proposals": len(re.findall(r"^##\s*[PA]\d+", opt_text or "", re.M)), "keep_as_is": keep}
    for k in ("ACCEPT", "MODIFY", "REJECT"):
        r[k.lower()] = len(re.findall(rf"VERDICT:\s*{k}\b", judge_text or ""))
    sev = [m.lower() for m in re.findall(r"^SEVERITY:\s*(critical|high|medium|low)", opt_text or "", re.M | re.I)]
    if sev:  # audit mode: severity of each Auditor finding, for the benchmark
        r["severity"] = {k: sev.count(k) for k in ("critical", "high", "medium", "low") if sev.count(k)}
    r["unresolved"] = len(re.findall(r"^##\s*UNRESOLVED", judge_text or "", re.M))
    return r


def parse_applied(text):
    m = re.search(r"^Applied:\s*(\d+)\s*/\s*(\d+)", text or "", re.M)
    return {"applied": int(m.group(1)), "of": int(m.group(2))} if m else {"applied": None, "of": None}


# ---------- commands ----------
def cmd_init(a):
    host = a.host or detect_host()
    if host not in CLIS:
        sys.exit(f"unknown host {host!r}: use {'|'.join(CLIS)}")
    slug = re.sub(r"[^a-z0-9]+", "-", (a.slug or "run").lower()).strip("-")[:40] or "run"
    rid = dt.datetime.now().strftime("%Y%m%d-%H%M") + "-" + slug
    run = AUDIT / rid
    run.mkdir(parents=True)
    latest = AUDIT / "latest"
    if latest.is_symlink() or latest.exists():
        latest.unlink()
    latest.symlink_to(rid)
    ext = [c for c in (os.environ.get("REFINE_EXTERNALS", "").split(",") if os.environ.get("REFINE_EXTERNALS")
                       else CLIS) if c and c != host]
    if len(ext) < 2:
        sys.exit(f"need at least two external CLIs besides host {host}: got {ext}")
    if len(set(ext)) < len(ext):
        sys.exit(f"refused: the same CLI twice in externals {ext} — a model must not judge its own report")
    opt, jud = ext[0], ext[1]
    reserve = ext[2] if len(ext) > 2 else None
    rounds = {"1": {"optimizer": opt, "judge": jud}}
    if a.rounds == 2:
        rounds["2"] = {"optimizer": jud, "judge": opt}
    meta = {"run": rid, "host": host, "mode": a.mode, "reserve": reserve, "cwd": os.getcwd(), "started": now(),
            "base_sha": git("rev-parse", "HEAD").strip() or None, "rounds": rounds, "calls": []}
    meta_save(run, meta)
    print(f"RUN={run}\nhost={host} (Primary) | mode={a.mode} | " + " | ".join(f"round {k}: optimizer={v['optimizer']} judge={v['judge']}"
                                                              for k, v in rounds.items()) + f" | reserve={reserve}\n"
          f"now write {run}/task.md (verbatim user task) and {run}/primary.md (your solution), then: refine.py round 1")


def cmd_round(a):
    run = run_dir(a.run)
    n = a.n
    meta = meta_load(run)
    if str(n) not in meta["rounds"]:
        sys.exit(f"this run has {len(meta['rounds'])} round(s): go to `refine.py finish`")
    if n == 2 and meta["rounds"]["1"].get("keep_as_is"):  # clean round 1: a second pass finds ~1 small item in 10 runs
        meta["rounds"]["2"]["state"] = "skipped"
        meta_save(run, meta)
        set_status(run, 2, "skipped", "round 1 returned KEEP AS IS / NO FINDINGS")
        print("round 2 skipped: round 1 found nothing to change — write final.md (Applied: 0/0) and run: refine.py finish")
        return
    sol = SOLUTION_FILE[n]
    for f in ("task.md", f"{sol}.md"):
        if not (run / f).exists():
            sys.exit(f"missing {run / f}: write it first")
    st = get_status(run, n)
    if st and st["state"] == "running":
        sys.exit(f"round {n} already running: {st['note']}")
    if os.environ.get("CODEX_SANDBOX"):
        sys.exit("refused: running inside the Codex sandbox — the external CLIs need network and write "
                 "access to their own home folders (~/.kimi-code, ~/.claude). Re-run this exact command "
                 "outside the sandbox (approve the escalation) or start codex with -s danger-full-access.")
    logf = open(run / "calls.log", "a")
    p = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_run", str(n), "--run", str(run)],
                         stdout=logf, stderr=logf, stdin=subprocess.DEVNULL, start_new_session=True)
    set_status(run, n, "running", f"starting (pid {p.pid})")
    r = meta["rounds"][str(n)]
    print(f"round {n} started in background (pid {p.pid}): optimizer={r['optimizer']} → judge={r['judge']}\n"
          f"next: refine.py wait {n}")


def cmd_run(a):
    """Internal: executed detached by `round`. Optimizer → Judge, files + status + meta."""
    run = run_dir(a.run)
    n = a.n
    meta = meta_load(run)
    r = meta["rounds"][str(n)]
    r["started"] = now()
    try:
        snapshot(run, SOLUTION_FILE[n], meta)
        opt_text = call(r["optimizer"], "optimizer", n, build_prompt(run, meta, "optimizer", n), run, meta)
        if opt_text is None:
            (run / f"optimizer-{n}.md").write_text(f"FAILED: {r['optimizer']} returned no usable report (see calls.log)\n")
            (run / f"judge-{n}.md").write_text("SKIPPED: no optimizer report\n")
            r["state"] = "failed"
        else:
            (run / f"optimizer-{n}.md").write_text(opt_text)
            if re.match(r"\s*(KEEP AS IS|NO FINDINGS)", opt_text):
                (run / f"judge-{n}.md").write_text(f"SKIPPED: {r['optimizer']} returned {opt_text.strip().splitlines()[0]} — nothing to judge\n")
                r["state"] = "done"
            else:
                judge_text = call(r["judge"], "judge", n, build_prompt(run, meta, "judge", n), run, meta)
                if judge_text is None:
                    (run / f"judge-{n}.md").write_text(f"FAILED: {r['judge']} returned no verdict (see calls.log); "
                                                       f"Primary decides on the optimizer report alone\n")
                    r["state"] = "failed"
                else:
                    (run / f"judge-{n}.md").write_text(judge_text)
                    r["state"] = "done"
    except Exception as e:  # keep the audit trail consistent whatever happened
        log(run, f"round {n} crashed: {e!r}")
        r["state"] = "failed"
        for f in (f"optimizer-{n}.md", f"judge-{n}.md"):
            if not (run / f).exists():
                (run / f).write_text(f"FAILED: {e}\n")
    r.update(parse_round(read(run / f"optimizer-{n}.md"), read(run / f"judge-{n}.md")))
    r["finished"] = now()
    meta_save(run, meta)
    set_status(run, n, r["state"], f"optimizer={r['optimizer']} judge={r['judge']}")


def cmd_wait(a):
    run = run_dir(a.run)
    n = a.n
    deadline = time.time() + a.timeout
    while True:
        st = get_status(run, n)
        if st is None:
            sys.exit(f"round {n} not started: refine.py round {n}")
        if st["state"] != "running":
            r = meta_load(run)["rounds"][str(n)]
            print(f"round {n} {st['state']}: proposals={r.get('proposals')} keep_as_is={r.get('keep_as_is')} "
                  f"accept={r.get('accept')} modify={r.get('modify')} reject={r.get('reject')} unresolved={r.get('unresolved')}\n"
                  f"read: {run}/judge-{n}.md (and optimizer-{n}.md)")
            if st["state"] not in ("done", "skipped"):
                errs = [c for c in meta_load(run)["calls"] if c["round"] == n and not c["ok"]]
                for c in errs:
                    print(f"  {c['role']} {c['cli']} attempt {c['attempt']}: rc={c.get('rc')} error={c.get('error')}")
                print(f"  details: {run}/calls.log")
            sys.exit(0 if st["state"] in ("done", "skipped") else 1)
        if time.time() > deadline:
            print(f"round {n} still running ({st['note']}, since {st['updated']}); call wait again")
            sys.exit(3)
        time.sleep(5)


def cmd_status(a):
    run = run_dir(a.run)
    meta = meta_load(run)
    print(f"run {run} host={meta['host']} started={meta['started']}")
    for n in (1, 2):
        st = get_status(run, n)
        print(f"  round {n}: {st['state'] if st else 'not started'} {st['note'] if st else ''}")
    for c in meta["calls"]:
        print(f"  {c['role']}-{c['round']} {c['cli']} attempt={c['attempt']} ok={c['ok']} {c['latency_s']}s")


def tokens(c):
    u = c.get("usage") or {}
    if not u:
        return "-"
    inp = u.get("input_tokens", 0) + u.get("cached_input_tokens", 0) + u.get("cache_read_input_tokens", 0) \
        + u.get("cache_creation_input_tokens", 0)
    return f"{inp}/{u.get('output_tokens', 0)}"


def cmd_finish(a):
    run = run_dir(a.run)
    meta = meta_load(run)
    snapshot(run, "final", meta)
    meta["finished"] = now()
    meta["applied"] = {"revision-1": parse_applied(read(run / "revision-1.md")), "final": parse_applied(read(run / "final.md"))}
    meta_save(run, meta)
    lines = [f"refine run {meta['run']} — host {meta['host']} (Primary) — mode {meta.get('mode', 'optimize')} — {meta['started']} → {meta['finished']}",
             f"{'call':14} {'cli':7} {'model':28} {'ok':3} {'sec':>7} {'tokens in/out':>16} {'cost$':>8}"]
    for c in meta["calls"]:
        lines.append(f"{c['role'] + '-' + str(c['round']) + '/' + str(c['attempt']):14} {c['cli']:7} "
                     f"{str(c.get('model') or '-')[:28]:28} {'Y' if c['ok'] else 'N':3} {c['latency_s']:>7} "
                     f"{tokens(c):>16} {str(c.get('cost_usd') if c.get('cost_usd') is not None else '-')[:8]:>8}")
    for n in (1, 2):
        if str(n) not in meta["rounds"]:
            continue
        r = meta["rounds"][str(n)]
        ap = meta["applied"]["final" if n == len(meta["rounds"]) else "revision-1"]
        lines.append(f"round {n}: {r.get('state', 'not run')} | optimizer={r['optimizer']} judge={r['judge']} | "
                     f"proposals={r.get('proposals')} keep_as_is={r.get('keep_as_is')} | accept={r.get('accept')} "
                     f"modify={r.get('modify')} reject={r.get('reject')} unresolved={r.get('unresolved')} | "
                     f"applied={ap['applied']}/{ap['of']}")
    lines.append(f"audit trail: {run}/")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("init", help="create .llm-audit/<run>/ and fix the role rotation")
    s.add_argument("--host", help="your own CLI: claude|codex|kimi|qwen (auto-detected for claude/codex)")
    s.add_argument("--slug", help="2-4 words for the run name")
    s.add_argument("--rounds", type=int, choices=(1, 2), default=2, help="1 = single round (optimizer → judge → final)")
    s.add_argument("--mode", choices=("optimize", "audit"), default="optimize",
                   help="optimize = second model simplifies (Optimizer); audit = second model hunts errors (adversarial Auditor)")
    for name, h in (("round", "start round N in the background (optimizer → judge)"),
                    ("wait", "block until round N finishes: exit 0 done, 1 failed, 3 still running"),
                    ("_run", argparse.SUPPRESS)):
        s = sub.add_parser(name, help=h)
        s.add_argument("n", type=int, choices=(1, 2))
        s.add_argument("--run")
        if name == "wait":
            s.add_argument("--timeout", type=int, default=550, help="seconds before returning exit 3")
    for name, h in (("status", "show run state"), ("finish", "snapshot final, write meta, print summary")):
        s = sub.add_parser(name, help=h)
        s.add_argument("--run")
    a = ap.parse_args()
    {"init": cmd_init, "round": cmd_round, "_run": cmd_run, "wait": cmd_wait, "status": cmd_status, "finish": cmd_finish}[a.cmd](a)


if __name__ == "__main__":
    main()
