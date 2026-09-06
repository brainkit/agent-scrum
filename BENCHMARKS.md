# Agent Scrum — benchmarks

**Method.** Every comparison is a pair of sessions started
simultaneously on the same build: Agent Scrum vs. a plain no-CRM agent,
identical prompts and fixtures, quality scored by held-out acceptance
tests the sessions never see (1M-context model). Costs are full
transcript sums — main session + every subagent, deduplicated by
request; the CLI's own `total_cost_usd` counts only the main session
and understates any spawning run 2-5x.

## Wall time — medians of 3 pairs per task (2026-09-06)

| Task | Agent Scrum | plain agent | runs (AS / plain) |
|---|---|---|---|
| bugfix | **160s** | 231s | 170,137,160 / 233,231,172 |
| feature | 119s | 120s | 122,116,119 / 115,120,171 |
| 20-ticket backlog | 229s | 210s | 405,207,229 / 192,259,210 |
| 60 tickets: PLAN lean vs prompt-only delegation | 369s | 305s | 369,379,313 / 305,356,287 |

Held-out quality was 100% in 22 of 24 runs; in the one degraded feature
repeat BOTH arms dropped points symmetrically — no arm gained anywhere.
Reading: bugfix favors Agent Scrum in all three runs (context packets);
feature is exact parity; the 20-ticket backlog is parity inside its own
spread (405→207 on identical runs); 60-ticket lean sits ~20% above the
delegation baseline — the price of the bookkeeping wave.

## Cost

- PLAN lean vs. delegation at equal decomposition (both 4 groups):
  **$13.7 vs $13.7** — the DB calls are token-free. Lean's spread across
  runs ($13.7-24.9) comes from group count and developer verbosity.
- Review stage (`reviewEnabled: true`), simultaneous pair, identical
  87/87 quality: 786s/$23.5 off vs 1159s/$30.5 on — **~+30%**; on a
  clean workload it returned zero tasks (it is drift insurance, not a
  quality boost).

## Measured laws (kept in the contracts)

- **Subagent turns are the cost driver** (~$0.10-0.13/turn — each turn
  re-reads the whole context as cache reads). The CRM's fixed context
  overhead (~12.5k tokens main, ~6k per developer) is cents.
- **Per-ticket handover was a regression — reverted.** It blew
  developers from ~13 to 27-55 turns ($13.7 → $32.3 for the same
  work); bookkeeping stays batched at start/finish only.
- **The wall gap lives before the wave.** Retyping the backlog into a
  context file delayed the first spawn +190s; a backlog that exists as
  a file is now passed by path, never copied (542s → 456s paired).
- **No speed crossover at scale.** 240 tickets: lean 2189s vs solo
  1181s, and solo's per-ticket cost grows slower too; context is not
  the binding constraint on a 1M window (solo peaked at ~19%).

Bottom line: choose the CRM for the guarantees (audit trail, Definition of Done check,
locks, liveness, restart-surviving state) — at best it matches the
no-CRM baseline on speed, and it never loses on quality.
