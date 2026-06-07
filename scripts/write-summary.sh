#!/usr/bin/env bash
set -euo pipefail

markdown_report="$REPORT_DIR/report.md"

if [[ -s "$markdown_report" ]]; then
  cat "$markdown_report" >> "$GITHUB_STEP_SUMMARY"
elif [[ "${HAS_BREAKING_CHANGES:-false}" == "false" ]]; then
  {
    echo "### Roseau"
    echo
    echo "No breaking changes detected."
  } >> "$GITHUB_STEP_SUMMARY"
fi
