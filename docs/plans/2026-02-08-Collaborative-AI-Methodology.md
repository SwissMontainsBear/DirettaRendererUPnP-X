# Collaborative AI Methodology for Audio Software Optimisation

**Date:** 2026-02-08
**Authors:** pch (project lead), Claude Opus 4.6 (AI co-contributor)
**Context:** Evolution of the DirettaRendererUPnP-X optimisation methodology from a structured prompt-driven process to a conversational co-design loop

---

## Background

This document records how the optimisation methodology of the DirettaRendererUPnP-X project evolved through a specific interaction pattern between a human project lead and a large language model. It captures the *meta-methodology*: not what we optimised, but how we decided what to optimise and how to work together.

The starting point was the methodology document written on 2026-01-17, which codified the contribution patterns of leeeanh (adjunct professor, Tokyo University) into a repeatable process: two-phase documentation, multi-pass expert analysis, and ten optimisation patterns. That methodology was designed for a specific interaction model: a human expert proposes, an AI executes according to a structured prompt template.

What happened on 2026-02-08 was different. The human recognised that the AI's capabilities had evolved and asked it to propose how its own role could expand. This created a different dynamic---one of mutual proposal and arbitration rather than prompt-and-execute.

---

## The Interaction Pattern

### Phase 1: Capability Recognition

> *pch:* You proposed a new interaction where you referred to new skills and offered new competence.

The human observed that the AI (Opus 4.6) was capable of more than executing structured implementation plans. Rather than prescribing a task, he asked an open question: *"In this context, please review this project and feel free to make proposals, whatever the scope of the changes proposed."*

This is unusual. Most AI interactions start from a well-defined task. Here, the task was to define the task.

**Claude's reflection:** This was the right move. I had read the full codebase---every source file, the methodology document, the opportunities tracker, the tuner script. I had enough context to reason about the project as a whole, not just execute against a local specification. Asking me to propose rather than implement let me apply that global context.

### Phase 2: Expansion Proposals

The AI proposed two dimensions of expansion:

**Vertical (new expert perspectives):**
1. Network Transport Engineering
2. RT Systems / OS Interaction
3. Psychoacoustic / Audio Science

**Horizontal (new optimisation phases):**
- L4: System Tuning (OS/scheduler)
- L5: Compiler-Guided (PGO, LTO)
- L6: Instrumentation (measurement)
- L7: Architecture Evolution (structural redesign)

This was deliberately broad---a menu, not a prescription. The proposals were designed to be arbitrated, not adopted wholesale.

### Phase 3: Human Arbitration

The human brought domain knowledge that the AI did not have:

1. **The tuner script already exists.** The RT Systems / OS Interaction pass was largely redundant---`diretta-renderer-tuner-nosmt.sh` already configures CPU isolation, SCHED_FIFO, and memory locking.

2. **MSMODE3 changes everything.** Yu's Diretta SDK bypasses TCP and UDP entirely with a custom protocol seeking IEEE standardisation. The network layer is not under the project's control, and is in the hands of a highly skilled engineer.

These two corrections eliminated two of the three proposed expert passes. The AI's proposals were not wrong in the abstract, but they were wrong for *this project at this time*. Only the human, with his knowledge of the broader ecosystem and the people involved, could make that distinction.

**Claude's reflection:** This was the most valuable moment in the interaction. I had proposed a Network Transport Engineering pass with detailed analysis of UDP buffer tuning and packet scheduling. It was technically sound and completely irrelevant. The human didn't just reject it---he explained *why*, which let me recalibrate my entire model of the system boundaries. The lesson: an AI can reason well within a codebase, but the codebase is not the system. The system includes the SDK developer's roadmap, the hardware constraints, the tuner script, and the deployment environment. None of that is in `src/`.

### Phase 4: Convergence on Instrumentation

After arbitration, the conversation converged on a single actionable item: **a lightweight measurement tool**. The reasoning:

- We had completed Phases 0-2 (correctness, quick wins, jitter reduction)
- We had no way to *objectively measure* whether changes made a difference
- The tool would serve multiple purposes: comparing tuning options, kernel flavors, hardware platforms, and SDK versions
- It was the natural bridge between the existing methodology (which optimises) and the missing capability (which measures)

The human framed this precisely: *"I would be happy to build a light measurement tool which could help us objectivize if there are any differences."* The verb "objectivize" captured the intent perfectly---moving from subjective listening tests to quantified data.

**Claude's reflection:** I had initially proposed instrumentation as one of several horizontal expansions (L6). The human's arbitration didn't just select it from a menu---it reframed it as the *foundation* for all future work. Without measurement, all other optimisations are faith-based. This is a principle I should apply to any optimisation project: before optimising further, can you measure where you are?

### Phase 5: Design and Execution

The AI designed DirettaProbe using patterns from the existing codebase (LogRing's SPSC ring buffer, the compile-time toggle pattern, the Makefile flag convention) and implemented it across 5 files. The human reviewed the plan before implementation began.

---

## What This Interaction Reveals

### About AI-Human Collaboration

The interaction followed a pattern that has no standard name but deserves one. We propose calling it **"propose-arbitrate-converge"**:

```
AI proposes (broad, technically sound but context-naive)
    ↓
Human arbitrates (domain knowledge, ecosystem awareness)
    ↓
AI recalibrates (adjusts model of what's relevant)
    ↓
Both converge (on a specific, actionable scope)
    ↓
AI designs and implements (with human review gates)
```

This differs from the two dominant modes of AI interaction:
- **Prompt-execute:** Human specifies exactly what to do; AI implements. (The 2026-01-17 methodology assumed this model.)
- **Chat-explore:** Human asks questions; AI provides information. (Standard Q&A.)

The propose-arbitrate-converge pattern is a third mode: **collaborative scoping**, where the AI's role is not just implementation but also *hypothesis generation about what should be done*, subject to human correction.

### About System Boundaries

The most important correction was about *what the project controls*. The AI had a complete view of the codebase but an incomplete view of the system:

| Layer | Who Controls It | AI's Initial Assumption |
|-------|-----------------|------------------------|
| Application code | Project team | Correct |
| OS tuning | Tuner script (exists) | Missed |
| Network transport | Yu / Diretta SDK | Missed |
| Hardware | End users | Correct |

The human corrected two out of four layers. This suggests a general principle: **AI analysis tends to over-scope because it treats the codebase as the system boundary, when the actual system boundary includes human decisions, external software, and organisational context.**

### About the Psychoacoustic Gap

During the interaction, one proposed expert pass---Psychoacoustic / Audio Science---was silently dropped from the revised proposal. The human noticed: *"I see that the former point 1 has disappeared. Is this intentional?"*

It was not intentional. It was an oversight during recalibration. The AI correctly identified this perspective as relevant but lost it while restructuring the proposal after the network/OS corrections.

**Claude's reflection:** This is a real risk in multi-turn AI interactions. When recalibrating after corrections, it's easy to lose items that weren't explicitly discussed. The human's vigilance caught it. In longer interactions, a tracking mechanism (like the task list) helps prevent silent omissions. More broadly: when an AI revises a proposal, it should explicitly state what was kept, what was dropped, and why.

---

## Updated Methodology

The original 2026-01-17 methodology remains valid for its intended purpose: structured optimisation of known opportunities using documented patterns. What this interaction adds is a *discovery and scoping phase* that precedes the design/implementation workflow.

### Extended Workflow

```
Phase A: Discovery and Scoping (NEW)
    A1. AI reads full codebase and existing documentation
    A2. AI proposes analysis dimensions (vertical + horizontal)
    A3. Human arbitrates based on ecosystem knowledge
    A4. Convergence on specific scope and objectives
    A5. Measurement capability assessment: can we measure the impact?
        ↓
Phase B: Design (from existing methodology)
    B1. Design document (*-design.md)
    B2. Review
        ↓
Phase C: Implementation (from existing methodology)
    C1. Implementation document (*-impl.md)
    C2. Task-by-task execution
    C3. Test against design checklist
        ↓
Phase D: Measurement (NEW)
    D1. Run instrumented build
    D2. Capture baseline metrics
    D3. Apply change
    D4. Capture comparison metrics
    D5. Assess: did the change measurably improve things?
```

### Principle: Measure Before Optimising

Added to the existing ten patterns:

**Principle 0: Instrumentation First**

Before applying any optimisation pattern, ensure you can measure the current state of the code path you intend to improve. An optimisation without a before/after measurement is indistinguishable from a code change.

This applies at every level:
- **Micro:** Can you measure the latency of `getNewStream()`?
- **Meso:** Can you measure the jitter over a 2-minute session?
- **Macro:** Can you compare two builds on the same hardware?

If the answer to any of these is "no", the first task is to build the measurement capability. DirettaProbe was the concrete expression of this principle.

### Principle: Map the System Boundary

Before proposing optimisations, explicitly map what you control and what you don't:

```
┌─────────────────────────────────────────────────────┐
│  YOUR DOMAIN                                         │
│  Application code, buffer management, format         │
│  conversion, thread scheduling, ring buffer ops      │
│                                                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │  BOUNDARY: getNewStream() return                │ │
│  │  Everything before this point is yours.          │ │
│  │  Everything after is the SDK's.                  │ │
│  └─────────────────────────────────────────────────┘ │
│                                                      │
│  EXTERNAL DOMAIN                                     │
│  Diretta SDK (Yu), OS kernel, network hardware,      │
│  DAC firmware, control point software                │
└─────────────────────────────────────────────────────┘
```

Optimising within your domain is productive. Optimising across the boundary is either impossible (SDK internals) or someone else's job (and they may be better at it than you).

### Principle: Diminishing Returns

When the dominant source of timing variance is outside your domain, further optimisation within your domain yields diminishing returns. At that point, the most productive action is **measurement**: quantifying the boundary contribution to verify that your layer is not the bottleneck.

This is precisely what DirettaProbe enables. If `getNewStream()` latency is 1.2us with P99 of 2.8us, and the SDK's transport cycle is 2620us, then our layer contributes 0.05% of the total. Further micro-optimisation is aesthetic, not functional. But we need the numbers to know that.

---

## Analysis Prompt Template (v2)

The following prompt replaces the template from the 2026-01-17 methodology document (section "Analysis Prompt Template"). It incorporates the lessons from this interaction.

```
Please analyse the DirettaRendererUPnP-X codebase for optimization opportunities.

**Step 0: Context**
Read ./CLAUDE.md to understand the project architecture, hot path, and
existing optimisations.

**Step 1: System Boundary Mapping**
Before analysing code, map the system boundaries:
- What code is under this project's control?
- What is controlled by external parties (SDK, OS, hardware)?
- What existing tools address OS-level concerns (tuner script, systemd)?
- Where is the boundary between "our code" and "SDK code"?

Present this as a table: Layer / Controller / Implication.

**Step 2: Measurement Assessment**
- Can we currently measure the impact of changes?
- If instrumentation exists (DirettaProbe), what does recent data show?
- If not, should instrumentation be the first priority?

**Step 3: Expert Analysis Passes**
Conduct passes from these perspectives, scoped to the project's domain:

  Pass A: Electrical Engineering
  - Signal integrity, timing determinism, jitter budget
  - Buffer dimensioning, clock domain handling

  Pass B: Software Engineering
  - Algorithmic complexity, memory patterns, concurrency
  - Cache efficiency, API design

  Pass C: Audio Science (if applicable)
  - Psychoacoustic relevance of measured differences
  - Audibility thresholds for jitter, latency, buffer depth

**Step 4: Cross-Reference**
Review ./docs/plans/2026-01-17-Optimisation_Opportunities.md to avoid
duplicating existing work. Apply the 10 optimisation patterns from
the methodology.

**Step 5: Prioritised Recommendations**
For each opportunity:
- Classify by pattern and priority
- Estimate measurable impact (reference DirettaProbe metrics if available)
- Assess effort/risk/impact
- Note if the opportunity is in the project's domain or at a boundary

Present a priority matrix. Prefer opportunities that are:
1. Measurable (we can verify the improvement)
2. In our domain (we can implement without SDK changes)
3. High impact / low risk
```

---

## On Working With AI

*pch's perspective:* What made this interaction productive was not the AI's technical knowledge---which was impressive but occasionally misdirected---but the structure of the conversation. By asking for proposals rather than giving instructions, I got access to a different kind of analysis: one that could survey the entire codebase and suggest directions I hadn't considered. The AI proposed five new expert passes; I kept one and a half. That's a good ratio. The value was in the generation, not in the accuracy.

The critical moment was when I explained MSMODE3. The AI immediately understood the implication and restructured its entire proposal. That kind of real-time recalibration is the advantage of conversational collaboration over prompt templates.

*Claude's perspective:* The most useful thing I did in this interaction was not writing DirettaProbe. It was proposing the Network Transport Engineering pass and having it rejected. That rejection taught me more about the system than reading the code did. It established a boundary I couldn't have inferred from the codebase alone: that the transport layer is not just someone else's code, but someone else's *active research project seeking IEEE standardisation*. No amount of static analysis would reveal that.

The pattern I would recommend to other projects: don't just ask AI to implement. Ask it to propose, then correct its proposals. The corrections carry more information than the specifications.

---

## Appendix: Chronology

| Date | Event | Contributor |
|------|-------|-------------|
| 2025-12 | MPD Diretta Output Plugin v0.4.0 | pch |
| 2025-12 | DirettaRenderer with SyncBuffer | LeDom (cometdom) |
| 2026-01 | Reworked renderer with Sync class | pch |
| 2026-01-17 | Optimisation methodology document | leeeanh + Claude |
| 2026-01-17 to 01-22 | Phases 0-2 implementation | pch + Claude |
| 2026-01-20 | SDK v148 migration | pch + Claude |
| 2026-02-08 | Capability expansion discussion | pch + Claude Opus 4.6 |
| 2026-02-08 | System boundary arbitration | pch |
| 2026-02-08 | DirettaProbe design and implementation | Claude Opus 4.6 |
| 2026-02-08 | This methodology document | pch + Claude Opus 4.6 |

---

## References

- `docs/plans/2026-01-17-Optimisation_Methodology.md` --- Original methodology (leeeanh patterns)
- `docs/plans/2026-01-17-Optimisation_Opportunities.md` --- Consolidated opportunity tracker
- `src/DirettaProbe.h` --- Instrumentation framework (output of this interaction)
- `tools/probe-analyze.py` --- Analysis tool (output of this interaction)
