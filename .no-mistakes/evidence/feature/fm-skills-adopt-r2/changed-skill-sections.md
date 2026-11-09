## diagnostic-reasoning (as delivered)
## Establish the observed behavior

Start from the end user's experience rather than an internal error string or an implementation hypothesis.
Before reading code to build a theory, have a named reproduction command aligned with the real user path: one command - a script path, a test invocation, a curl - already run at least once with its invocation and output shown, and red-capable, deterministic, fast, and agent-runnable.
Reading code to build a theory before that command exists is the exact failure this procedure prevents.
If a faithful reproduction is not feasible or not safe, record the exact limitation and use the closest representative path without presenting it as equivalent evidence.
Capture the expected behavior, observed behavior, setup, inputs, and repeatability before assigning a cause.

Separate these three facts explicitly:
## Scope and act on the result

A diagnosis brief should ask for the reproduction, trigger/mask/symptom separation, divergent and proven path comparison, relevant history, smallest counterfactual, and disconfirming evidence in the report.
It should also require the investigation to tag every debug log it adds with a unique prefix such as `[DEBUG-a4f2]` and to grep that prefix to delete all of them before reporting, so cleanup is a single pass and pre-existing untagged logging survives it.
A diagnostic report should distinguish observed facts from hypotheses and state any unresolved uncertainty that could change the recommended scope.
Before acting on the report, verify that its claimed cause explains the end-user reproduction and the proven path without relying on an untested masking condition.
If a load-bearing element is missing, route a focused follow-up investigation instead of treating confidence or implementation detail as proof.
A diagnosis or implementation-ready recommendation is evidence, not authorization to change code.

## firstmate-coding-guidelines new section
## Lines that earn their load

Size discipline governs where a fact goes; these three levers govern whether a line should exist at all and how it should be phrased.
They apply to every document an agent consumes: `AGENTS.md`, a skill, a brief scaffold, or a doc one of those points at.

**The no-op test.**
Hunt no-ops sentence by sentence: an instruction the model already obeys by default pays load to say nothing.
The test - does this sentence change behavior versus the default? - is model-relative, not reader-relative, so two people disagreeing about a no-op disagree about the default and settle it by running the document rather than by debate.
When a sentence fails the test, delete the whole sentence rather than trim words from it.
Scoping rule for safety lines: on a surface carrying a safety boundary, "the model already does this by default" is a claim that needs evidence before the line goes, because a default can drift between model versions and some prohibitions are load-bearing for exactly that reason.
Keep such a line until that evidence exists, and run a sweep of an always-loaded contract as its own task with its own review rather than as a side effect of another change.

**Negation is a failure mode.**
Steering by prohibition drags the forbidden behavior into context and makes it more available, not less: the negation is a weak modifier that the strongly activated concept overruns, so the ban half-reads as an instruction to do the thing.
Prompt the positive, stating the target behavior rather than its opposite.
A prohibition earns its place only as a hard guardrail you cannot phrase positively, such as `AGENTS.md`'s "never write to a project"; even then, pair it with the positive target.
In material you are drafting, read a long enumerated ban list as a signal that the positive statement is missing, or that it is already there and doing the real work.
On a surface carrying a safety boundary, this lever is a reading, not a license: rewriting its prohibitions into positives is its own task with its own review, never a side effect of another change.

**Completion criteria, and premature completion.**
Every step you write for an agent ends on a completion criterion, judged on two axes.
Clarity is whether the agent can tell done from not-done: a vague bound ("understanding reached") invites premature completion, where the step ends before it is genuinely done because attention has slipped to being done.
Demand is how much the criterion requires: "every modified model accounted for" forces thorough work where "produce a change list" does not.
The visible steps still ahead supply the pull toward premature completion, and the criterion's clarity is the resistance.
Defend in that order: sharpen the bound first, and only if it is irreducibly fuzzy and you observe the rush, hide the later steps by splitting the sequence.
Splitting only works across a real context boundary such as a hand-off or a subagent dispatch, because an inline call leaves the later steps in context and clears nothing.

## Trigger hygiene
