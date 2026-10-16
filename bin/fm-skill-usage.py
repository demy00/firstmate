#!/usr/bin/env python3
"""The transcript parser behind fm-skill-usage.sh; that script's header owns the contract."""

import argparse
import datetime as dt
import glob
import json
import os
import re
import sys
from collections import defaultdict

BRIEF_MARKER = "FIRSTMATE_OP: v1 launch-brief"
# The lifecycle skills the brief scaffold (bin/fm-brief.sh) names for every
# ship or scout, so loading one says nothing about the task's own skills.
BASELINE_SKILLS = ("no-mistakes", "captain-hold-lifecycle")
INBOX_RE = re.compile(r"state/([A-Za-z0-9._-]+)\.inbox")
TREEHOUSE_RE = re.compile(r"/\.treehouse/[^/]+/[^/]+/([^/]+)")
READ_LINE_PREFIX_RE = re.compile(r"^\s*\d+\t")
REQUIRED_ITEM_RE = re.compile(r"^- `([^`]+)`")
SKILL_FILE_RE = re.compile(r"([A-Za-z0-9._:-]+)/SKILL\.md$")
BASH_SKILL_READ_RE = re.compile(
    r"\b(?:cat|head|tail|sed|less|more|bat)\b[^|;&\n]*?(?<![$\w.:-])([A-Za-z0-9._:-]+)/SKILL\.md"
)
BASE_DIR_RE = re.compile(r"Base directory for this skill: (\S+)")


def skill_name(raw):
    """Normalize a skill reference: drop a leading slash and any plugin prefix."""
    return raw.strip().lstrip("/").rsplit(":", 1)[-1]


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            text_of(item.get("text", item.get("content", ""))) if isinstance(item, dict) else str(item)
            for item in content
        )
    return ""


def required_skills(brief):
    """Return the skills a brief's `# Required skills` section names, or None without one."""
    lines = [READ_LINE_PREFIX_RE.sub("", line, count=1) for line in brief.splitlines()]
    names, inside = None, False
    for line in lines:
        if line.strip() == "# Required skills":
            names, inside = [], True
            continue
        if inside:
            if line.startswith("# "):
                break
            match = REQUIRED_ITEM_RE.match(line)
            if match:
                names.append(skill_name(match.group(1)))
    return names


def parse_time(stamp):
    try:
        return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def entries(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue  # a transcript still being written can end in a partial line
            if isinstance(entry, dict) and entry.get("type") in ("user", "assistant"):
                yield entry


def scan_transcript(path):
    """Return the task one worker transcript records, or None when it carries no launch brief."""
    brief = None
    cwd = None
    start = None
    loads = set()
    for entry in entries(path):
        cwd = cwd or entry.get("cwd")
        stamp = parse_time(entry.get("timestamp"))
        if stamp and (start is None or stamp < start):
            start = stamp
        content = (entry.get("message") or {}).get("content")
        blocks = [{"type": "text", "text": content}] if isinstance(content, str) else content or []
        for block in blocks:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "tool_result":
                if brief is None:
                    result = text_of(block.get("content"))
                    if BRIEF_MARKER in result:
                        brief = result
            elif kind == "text" and entry["type"] == "user":
                text = block.get("text") or ""
                if brief is None and BRIEF_MARKER in text:
                    brief = text
                for match in BASE_DIR_RE.finditer(text):
                    loads.add(skill_name(os.path.basename(match.group(1).rstrip("/"))))
            elif kind == "tool_use":
                tool, args = block.get("name"), block.get("input") or {}
                if tool == "Skill" and args.get("skill"):
                    loads.add(skill_name(args["skill"]))
                elif tool == "Read":
                    match = SKILL_FILE_RE.search(str(args.get("file_path", "")))
                    if match:
                        loads.add(skill_name(match.group(1)))
                elif tool == "Bash":
                    for match in BASH_SKILL_READ_RE.finditer(str(args.get("command", ""))):
                        loads.add(skill_name(match.group(1)))
    if brief is None or start is None:
        return None
    task_match = INBOX_RE.search(brief)
    required = required_skills(brief)
    repo_match = TREEHOUSE_RE.search(cwd or "")
    return {
        "id": task_match.group(1) if task_match else os.path.splitext(os.path.basename(path))[0],
        "repo": repo_match.group(1) if repo_match else os.path.basename((cwd or "").rstrip("/")) or "unknown",
        "kind": "ship" if re.search(r"^(?:\s*\d+\t)?Delivery contract: mode=", brief, re.M) else "scout",
        "start": start,
        "required": required or [],
        "has_section": required is not None,
        "loads": loads,
    }


def collect(claude_root, since, until):
    tasks = {}
    for path in sorted(glob.glob(os.path.join(claude_root, "projects", "*treehouse*", "*.jsonl"))):
        found = scan_transcript(path)
        if found is None:
            continue
        task = tasks.get(found["id"])
        if task is None:
            tasks[found["id"]] = found
            continue
        task["start"] = min(task["start"], found["start"])
        task["loads"] |= found["loads"]
        task["has_section"] = task["has_section"] or found["has_section"]
        task["required"] = sorted(set(task["required"]) | set(found["required"]))
    return [t for t in tasks.values() if since <= t["start"].astimezone().date() <= until]


def counted(counter):
    return ", ".join(f"{key} {n}" for key, n in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0])))


def installed_skills(claude_root):
    return sorted(
        os.path.basename(os.path.dirname(path)) for path in glob.glob(os.path.join(claude_root, "skills", "*", "SKILL.md"))
    )


def render(tasks, since, until, installed):
    out = [f"## Skill usage {since.isoformat()}..{until.isoformat()}", ""]
    if not tasks:
        out.append("No worker tasks started in this range.")
        return "\n".join(out)
    repos = defaultdict(int)
    for task in tasks:
        repos[task["repo"]] += 1
    with_section = sum(1 for t in tasks if t["has_section"])
    out.append(f"{len(tasks)} worker tasks started ({counted(repos)}); {with_section} had a `# Required skills` section.")
    out.append("")

    loaded_by = defaultdict(lambda: defaultdict(int))
    named = defaultdict(int)
    missed = []
    for task in tasks:
        for name in task["loads"]:
            loaded_by[name][task["repo"]] += 1
        for name in task["required"]:
            named[name] += 1
            if name not in task["loads"]:
                missed.append(f"`{name}` ({task['id']})")
    rows = sorted(
        set(loaded_by) | set(named), key=lambda name: (-sum(loaded_by[name].values()), name)
    )
    out += ["| Skill | Tasks | Named in brief | By repo |", "|---|---|---|---|"]
    for name in rows:
        out.append(f"| `{name}` | {sum(loaded_by[name].values())} | {named[name]} | {counted(loaded_by[name]) or '-'} |")
    out.append("")
    if missed:
        out += [f"Named in the brief but not loaded: {', '.join(sorted(missed))}.", ""]

    bare = [t for t in tasks if not (t["loads"] - set(BASELINE_SKILLS))]
    ships = [t for t in tasks if t["kind"] == "ship"]
    bare_ships = [t for t in bare if t["kind"] == "ship"]
    out.append(
        f"No skill beyond {' and '.join(f'`{n}`' for n in BASELINE_SKILLS)}: {len(bare)} of {len(tasks)} tasks "
        f"({len(bare_ships)} of {len(ships)} ship tasks)."
    )
    by_repo = defaultdict(list)
    for task in sorted(bare, key=lambda t: t["id"]):
        by_repo[task["repo"]].append(task["id"] + (" (scout)" if task["kind"] == "scout" else ""))
    for repo in sorted(by_repo):
        out.append(f"- {repo}: {', '.join(by_repo[repo])}")

    unused = [name for name in installed if name not in loaded_by]
    if unused:
        out += ["", f"Installed skills no task loaded: {', '.join(f'`{n}`' for n in unused)}."]
    return "\n".join(out)


def day(value):
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a YYYY-MM-DD date: {value}")


def week(value):
    match = re.fullmatch(r"(\d{4})-W(\d{2})", value)
    try:
        if not match:
            raise ValueError
        monday = dt.date.fromisocalendar(int(match.group(1)), int(match.group(2)), 1)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a YYYY-Www ISO week: {value}")
    return monday


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, f"error: {message}\n")


def main(argv):
    parser = Parser(prog="fm-skill-usage.sh", add_help=False)
    parser.add_argument("--claude-root", required=True)
    parser.add_argument("--since", type=day)
    parser.add_argument("--until", type=day)
    parser.add_argument("--week", type=week)
    args = parser.parse_args(argv)
    if args.week and (args.since or args.until):
        parser.error("--week and --since/--until are exclusive")
    if bool(args.since) != bool(args.until):
        parser.error("--since and --until go together")
    if args.week:
        since = args.week
    elif args.since:
        since = args.since
    else:
        today = dt.date.today()
        since = today - dt.timedelta(days=today.weekday() + 7)
    until = args.until or since + dt.timedelta(days=6)
    if until < since:
        parser.error("--until is before --since")
    if not os.path.isdir(args.claude_root):
        parser.error(f"Claude root not found: {args.claude_root}")
    print(render(collect(args.claude_root, since, until), since, until, installed_skills(args.claude_root)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
