# Typed skill selection verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-skill-select.sh` contract owned by [`../configuration.md`](../configuration.md) ("Typed skill selection").
It records only facts that must be re-established when the typesafe.ai model, its API, or the per-harness skill directories change.
The API facts shared with the dispatch resolver are in [`dispatch-resolve.md`](dispatch-resolve.md).

## Question types the API offers

Checked 2026-10-01 against `GET https://api.typesafe.ai/openapi.json`.
`POST /v1/systemone` accepts three question types: `choice` (one option from named criteria, answered with `choice`, `confidence`, and `probabilities` summing to 1), `noul` (a yes/no question, answered with `noul`, the probability of yes), and `score` (an ordered rubric).
There is no multi-label type, so the two candidate shapes were one `choice` question over all skills and one `noul` question per skill, all in one request.

## Live comparison on real briefs

Run 2026-10-01 against `jev-latest`, answering as `jev-1.13.0`, twice per brief and shape.
State was the project name and the brief text `bin/fm-typesafe-lib.sh` sends; candidates were each brief's `--candidates` list for the `claude` harness (14 to 43 skills).
The `noul` shape asked, per skill, "Should the agent doing `task` load the skill `<name>` before starting? The skill describes itself as: `<description>`" with fixed true and false criteria, exactly as the shipped tool does.
The `choice` shape offered every skill as `<name>: <description>` plus a `none` option.
Nine real briefs from this home were hand-labeled before any call: four web-frontend tasks (a dead-component deletion, an end-to-end lane repair, a permission-gating feature, a chat UI build), a design-system lint fix, a dotfiles skill addition (labeled no skill), a firstmate bug fix, an Expo phase-1 build, and a Python bug fix.

| Measure | One yes/no per skill (floor 0.8) | One Choice |
| --- | --- | --- |
| Labeled skills found | 16 of 24 | 8 of 24 (top pick) |
| Unlabeled skills selected | 3 | 0 |
| Briefs matching the label exactly | 5 of 9 | 3 of 9 |
| Same selection on both runs | 9 of 9 | 9 of 9 |
| Latency (min / median / max) | 348 / 420 / 506 ms | 341 / 400 / 742 ms |
| Input tokens per brief (min / median / max) | 2,661 / 3,796 / 7,879 | 1,753 / 2,468 / 4,941 |
| Output tokens | 261 to 812 | 157 to 448 |
| API errors | 0 | 0 |

A Choice answer concentrates its probability on one option, so it cannot name the two to six skills most tasks need; thresholding its probabilities at 0.1 found only 11 of 24.
One yes/no question per skill costs about 1.5 times the input tokens at the same latency and is the shipped shape.
The largest run-to-run difference in any probability was 0.06.

Floor sweep for the yes/no shape over the same nine briefs:

| Floor | Labeled found | Unlabeled selected | Exact briefs |
| --- | --- | --- | --- |
| 0.7 | 16 | 12 | 1 |
| 0.8 | 16 | 3 | 5 |
| 0.85 | 13 | 3 | 3 |
| 0.9 | 9 | 0 | 3 |

0.8 is the shipped floor: below it the lifecycle skill `no-mistakes` (0.71 to 0.78, already driven by the brief's own definition of done) and loosely related skills start to be selected, and above it real matches drop out.
The three unlabeled selections were `pipeline` twice and `tdd` once, each on a feature or bug-fix brief that its own description claims ("Use when building any non-trivial feature", "Use whenever implementing a spec or fixing a bug").
The misses were mostly secondary skills a long brief only implies, such as `vitest` (0.42 and 0.53) and `tanstack` on frontend feature briefs.
The no-skill dotfiles brief stayed below 0.3 for every candidate.

## End-to-end run of the shipped tool

Run 2026-10-01 on a copy of the design-system lint brief, with the key from the home `.env`:

```console
$ FM_HOME=<home> bin/fm-skill-select.sh <copy>/brief.md --project design-system --harness claude --apply
skill-select:
  status: clear
  model: jev-1.13.0   latency_ms: 0   tokens: 2661/261
  skill: shadcn p=0.97 -> selected
  skill: typescript p=0.81 -> selected
  skill: ui-design p=0.79 -> below floor
  skill: no-mistakes p=0.71 -> below floor
  ...
  skills: shadcn typescript
  brief: written
```

The `latency_ms: 0` is the macOS `/bin/bash` 3.2 clock, which has whole-second resolution; the latencies in the table above were measured by the comparison client.
The brief gained one `# Required skills` section between `# Task` and the next section and was otherwise byte-identical, and `--clear` restored it byte for byte.

## Offline behavior

`tests/fm-skill-select.test.sh` drives the public interface with an isolated `HOME`, home, and project clone, and a fake `curl` that answers each yes/no question by skill name.
It proves the absent key, an unsupported harness, no candidates, and a never-send match are off with no network call and an unchanged brief.
It proves candidates follow each harness's directories, frontmatter names, folded and quoted descriptions, the pinned Claude root (an unresolvable pin exits 2 once with no network call), and the exclusion of description-less and `disable-model-invocation` skills.
It proves one yes/no question per candidate carrying only the name and description, never a skill body or the scaffold boilerplate, with the key only on file descriptor 3.
It proves the 0.8 floor at its boundary, `none` and `error` outcomes that leave the brief untouched, the section's position and in-place rewrite, `--set` validation, and `--clear`.

```console
$ bash tests/fm-skill-select.test.sh | tail -1
# all fm-skill-select tests passed
```

A live run needs a key and is not part of the suite; rerun the end-to-end command above on any brief to refresh this record.
