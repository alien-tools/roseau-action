#!/usr/bin/env bash
set -euo pipefail

marker="<!-- roseau-action -->"
markdown_report="$REPORT_DIR/report.md"

if [[ "${HAS_BREAKING_CHANGES:-false}" == "true" && -f "$markdown_report" ]]; then
  body="$marker"$'\n'"$(cat "$markdown_report")"
else
  body="$marker"$'\n'"### Roseau: no breaking changes detected"
fi

set +e
comment_id="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
  --jq "[.[] | select(.body | startswith(\"$marker\"))][0].id // empty")"
status=$?
set -e

if (( status != 0 )); then
  echo "::warning::Could not list PR comments. Check workflow permissions if PR comments are enabled."
  exit 0
fi

set +e
if [[ -n "$comment_id" ]]; then
  gh api "repos/$GITHUB_REPOSITORY/issues/comments/$comment_id" -X PATCH -f body="$body"
  status=$?
else
  gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" -f body="$body"
  status=$?
fi
set -e

if (( status != 0 )); then
  echo "::warning::Could not create or update the Roseau PR comment. Check workflow permissions if PR comments are enabled."
fi
