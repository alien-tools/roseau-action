#!/usr/bin/env bash
set -euo pipefail

marker="<!-- roseau-action -->"
markdown_report="$REPORT_DIR/report.md"
inline_summary="$REPORT_DIR/inline.md"
comparison="$REPORT_DIR/comparison.md"
# GitHub rejects comments longer than 65536 characters
max_length=60000

if [[ "${HAS_BREAKING_CHANGES:-false}" == "true" && -f "$markdown_report" ]]; then
  report="$(cat "$markdown_report")"
  if (( ${#report} > max_length )); then
    report="${report:0:max_length}"$'\n\n'"_The report is truncated; see the \`roseau-reports\` artifact of this run for the full report._"
  fi
  body="$marker"$'\n'"$(cat "$comparison" 2>/dev/null)"$'\n\n'"$report"
  if [[ -s "$inline_summary" ]]; then
    body+=$'\n'"$(cat "$inline_summary")"
  fi
else
  body="$marker"$'\n'"### Roseau: no breaking changes detected"$'\n\n'"$(cat "$comparison" 2>/dev/null)"
fi

warn() {
  # Make sure the workflow command starts on its own line, after any gh output
  echo
  echo "::warning::$1 The PR comment requires the 'pull-requests: write' permission, which pull requests from forks do not get."
}

if ! comment_id="$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
  --jq ".[] | select(.body | startswith(\"$marker\")) | .id" | head -n 1)"; then
  warn "Could not list PR comments."
  exit 0
fi

if [[ -n "$comment_id" ]]; then
  gh api "repos/$GITHUB_REPOSITORY/issues/comments/$comment_id" -X PATCH -f body="$body" > /dev/null \
    || warn "Could not update the Roseau PR comment."
else
  gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" -f body="$body" > /dev/null \
    || warn "Could not create the Roseau PR comment."
fi
