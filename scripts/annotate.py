#!/usr/bin/env python3
"""Anchor Roseau breaking changes to the lines of a pull request diff.

Each breaking change is anchored to the most precise line available in the pull request diff:

1. its new location (``newLocation``), on the new side of the diff: modified and added symbols;
2. its old location (``location``), on the old side of the diff when that line was deleted: removed symbols,
   or on the new side when that line is unchanged context.

Anchored changes are reported as inline review comments, updated in place across runs. Workflow annotations
mark the changes that inline comments cannot: all of them when comments cannot be posted (e.g., pull requests from
forks), and changes outside the diff in their unchanged file. All changes remain listed in the summary comment.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field

MARKER = "<!-- roseau-action:inline:"
HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
DOCS = "https://alien-tools.github.io/roseau/stable/breaking-change-kinds/"


@dataclass
class FileDiff:
    """The commentable lines of one file of a pull request, parsed from its unified diff."""

    path: str
    old_path: str
    status: str
    deleted: set[int] = field(default_factory=set)
    added: set[int] = field(default_factory=set)
    context: dict[int, int] = field(default_factory=dict)
    removed_at: dict[int, int] = field(default_factory=dict)

    @classmethod
    def parse(cls, entry: dict) -> FileDiff:
        diff = cls(entry["filename"], entry.get("previous_filename") or entry["filename"], entry["status"])
        old = new = 0
        for line in (entry.get("patch") or "").splitlines():
            if match := HUNK.match(line):
                old, new = int(match[1]), int(match[2])
            elif line.startswith("-"):
                diff.deleted.add(old)
                diff.removed_at[old] = max(new, 1)
                old += 1
            elif line.startswith("+"):
                diff.added.add(new)
                new += 1
            elif line.startswith(" ") or not line:  # Empty lines are context lines stripped of their space
                diff.context[old] = new
                old += 1
                new += 1
        return diff


@dataclass(frozen=True)
class Anchor:
    path: str
    side: str
    line: int
    annotation_line: int | None


def find(files: list[FileDiff], path: str, old: bool) -> FileDiff | None:
    """Returns the only file of the diff whose repository path ends with a source-root-relative path."""
    matches = [f for f in files
               if f.status != ("added" if old else "removed")
               and ((f.old_path if old else f.path) == path or (f.old_path if old else f.path).endswith("/" + path))]
    return matches[0] if len(matches) == 1 else None


def anchor(change: dict, files: list[FileDiff]) -> Anchor | None:
    new = change.get("newLocation")
    if new and new.get("line"):
        f = find(files, new["path"], old=False)
        if f and (new["line"] in f.added or new["line"] in f.context.values()):
            return Anchor(f.path, "RIGHT", new["line"], new["line"])

    old = change.get("location")
    if old and old.get("line"):
        f = find(files, old["path"], old=True)
        if f and old["line"] in f.deleted:
            return Anchor(f.path, "LEFT", old["line"], None if f.status == "removed" else f.removed_at[old["line"]])
        if f and old["line"] in f.context:
            line = f.context[old["line"]]
            return Anchor(f.path, "RIGHT", line, line)
    return None


def unchanged_location(change: dict, tracked: list[str]) -> tuple[str, int] | None:
    """Locates a change outside the diff in a file the pull request does not modify."""
    for key in ("newLocation", "location"):
        location = change.get(key)
        if location and location.get("line"):
            matches = [p for p in tracked if p == location["path"] or p.endswith("/" + location["path"])]
            if len(matches) == 1:
                return matches[0], location["line"]
    return None


def compatibility(change: dict) -> str:
    binary, source = change.get("binaryBreaking"), change.get("sourceBreaking")
    if binary and source:
        return "binary-breaking and source-breaking"
    return "binary-breaking only" if binary else "source-breaking only"


def title(change: dict) -> str:
    return change["kind"].replace("_", " ").capitalize()


def message(change: dict) -> str:
    symbol = change["impactedSymbol"]
    new_symbol = change.get("newSymbol")
    if new_symbol and new_symbol != symbol:
        return f"{symbol} → {new_symbol} ({compatibility(change)})"
    return f"{symbol} ({compatibility(change)})"


def describe(change: dict) -> str:
    return f"{title(change)}: {message(change)}"


def fingerprint(changes: list[dict], where: Anchor) -> str:
    key = [sorted([c["kind"], c["impactedSymbol"], c.get("newSymbol") or ""] for c in changes),
           where.path, where.side, where.line]
    return hashlib.sha256(json.dumps(key).encode()).hexdigest()[:16]


def comment_body(changes: list[dict], where: Anchor) -> str:
    heading = "breaking change" if len(changes) == 1 else f"{len(changes)} breaking changes"
    lines = [f"**Roseau: {heading}**", ""]
    for change in changes:
        symbol, new_symbol = change["impactedSymbol"], change.get("newSymbol")
        line = f"- **{title(change)}** ([`{change['kind']}`]({DOCS}#{change['kind'].lower()})): `{symbol}` is {compatibility(change)}."
        if new_symbol and new_symbol != symbol:
            line += f" New symbol: `{new_symbol}`."
        lines.append(line)
    lines += ["", f"{MARKER}{fingerprint(changes, where)} -->"]
    return "\n".join(lines)


def escape_property(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A").replace(":", "%3A").replace(",", "%2C")


def escape_data(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def annotation(level: str, changes: list[dict], path: str | None, line: int | None) -> str:
    heading = title(changes[0]) if len(changes) == 1 else f"{len(changes)} breaking changes"
    props = [f"title={escape_property('Roseau: ' + heading)}"]
    if path:
        props.insert(0, f"file={escape_property(path)}")
        if line:
            props.insert(1, f"line={line}")
    text = message(changes[0]) if len(changes) == 1 else "\n".join(describe(c) for c in changes)
    return f"::{level} {','.join(props)}::{escape_data(text)}"


def should_annotate(mode: str, commented: bool, outside_located: bool = False) -> bool:
    """Whether to annotate changes; in auto mode, only those that inline comments do not mark."""
    if mode == "false":
        return False
    return mode == "true" or not commented or outside_located


def gh(*args: str, payload: dict | None = None) -> str:
    result = subprocess.run(["gh", "api", *args] + (["--input", "-"] if payload is not None else []),
                            input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip())
    return result.stdout


def json_stream(text: str) -> list:
    decoder, items, index = json.JSONDecoder(), [], 0
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        item, index = decoder.raw_decode(text, index)
        items.append(item)
    return items


def sync_review_comments(repo: str, pr: str, head_sha: str, groups: dict[Anchor, list[dict]]) -> tuple[int, int, int]:
    """Creates missing inline comments, updates outdated bodies, and deletes stale ones.

    Returns the number of (kept, created, deleted) comments.
    """
    wanted = {fingerprint(changes, where): (changes, where) for where, changes in groups.items()}
    existing = json_stream(gh("--paginate", f"repos/{repo}/pulls/{pr}/comments", "--jq", ".[]"))
    kept, deleted = set(), 0
    for comment in existing:
        body = comment.get("body") or ""
        if MARKER not in body:
            continue
        fp = body.split(MARKER, 1)[1].split(" ", 1)[0]
        current = wanted.get(fp)
        # Outdated comments have no line anymore: recreate them on the current diff
        if current and fp not in kept and comment.get("line") == current[1].line and comment.get("side") == current[1].side:
            kept.add(fp)
            if body != (new_body := comment_body(*current)):
                gh("-X", "PATCH", f"repos/{repo}/pulls/comments/{comment['id']}", payload={"body": new_body})
        else:
            gh("-X", "DELETE", f"repos/{repo}/pulls/comments/{comment['id']}")
            deleted += 1

    missing = [(changes, where) for fp, (changes, where) in wanted.items() if fp not in kept]
    if missing:
        count = sum(len(changes) for changes, _ in missing)
        gh(f"repos/{repo}/pulls/{pr}/reviews", payload={
            "commit_id": head_sha,
            "event": "COMMENT",
            "body": f"Roseau detected {count} new breaking change(s) in this diff.",
            "comments": [{"path": w.path, "line": w.line, "side": w.side, "body": comment_body(c, w)} for c, w in missing],
        })
    return len(kept), len(missing), deleted


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--report", required=True, help="Roseau JSON report")
    parser.add_argument("--pr-files", help="PR files as returned by the GitHub API; fetched with gh if omitted")
    parser.add_argument("--summary", help="Markdown file where the anchoring summary is written")
    parser.add_argument("--level", default="error", choices=["error", "warning", "notice"])
    parser.add_argument("--annotations", default="auto", choices=["auto", "true", "false"],
                        help="auto: only annotate breaking changes that inline comments do not mark")
    parser.add_argument("--inline-comments", action=argparse.BooleanOptionalAction, default=True)
    args = parser.parse_args()

    repo, pr, head_sha = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("PR_NUMBER"), os.environ.get("HEAD_SHA")
    with open(args.report) as f:
        changes = json.load(f)

    if args.pr_files:
        with open(args.pr_files) as f:
            entries = json.load(f)
    else:
        entries = json_stream(gh("--paginate", f"repos/{repo}/pulls/{pr}/files", "--jq", ".[]"))
    files = [FileDiff.parse(e) for e in entries]
    tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.splitlines()

    groups: dict[Anchor, list[dict]] = {}
    outside: dict[tuple[str, int] | None, list[dict]] = {}
    for change in changes:
        where = anchor(change, files)
        if where:
            groups.setdefault(where, []).append(change)
        else:
            outside.setdefault(unchanged_location(change, tracked), []).append(change)

    for where, group in groups.items():
        print(f"{where.path}:{where.line} ({where.side}): " + "; ".join(f"{c['kind']} {c['impactedSymbol']}" for c in group))
    for location, group in outside.items():
        print("<outside diff>: " + "; ".join(f"{c['kind']} {c['impactedSymbol']}" for c in group))

    status, commented = "", False
    if args.inline_comments and not args.pr_files:
        try:
            kept, created, deleted = sync_review_comments(repo, pr, head_sha, groups)
            print(f"Inline comments: {kept} kept, {created} created, {deleted} deleted")
            commented = True
        except RuntimeError as error:
            print(f"\n::warning::Could not update Roseau inline comments ({error}). "
                  "They require the 'pull-requests: write' permission, which pull requests from forks do not get. "
                  "Breaking changes are annotated instead.")
            status = " Inline comments could not be posted."

    if should_annotate(args.annotations, commented):
        for where, group in groups.items():
            print(annotation(args.level, group, where.path if where.annotation_line else None, where.annotation_line))
    for location, group in outside.items():
        if location and should_annotate(args.annotations, commented, outside_located=True):
            print(annotation(args.level, group, *location))
        elif not location and should_annotate(args.annotations, commented):
            for change in group:
                print(annotation(args.level, [change], None, None))

    if args.summary and changes:
        marked = sum(len(group) for group in groups.values())
        with open(args.summary, "w") as f:
            f.write(f"\n{marked} of {len(changes)} breaking change(s) are marked on the lines of this diff.{status}\n")
            if outside:
                f.write("\nOutside this diff:\n\n")
                for group in outside.values():
                    for change in group:
                        f.write(f"- `{change['kind']}` on `{change['impactedSymbol']}`\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
