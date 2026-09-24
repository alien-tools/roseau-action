#!/usr/bin/env bash
set -euo pipefail

markdown_report="$REPORT_DIR/report.md"
comparison="$REPORT_DIR/comparison.md"

{
  echo "### Roseau report"
  echo
  [[ -s "$comparison" ]] && { cat "$comparison"; echo; }
  if [[ -s "$markdown_report" ]]; then
    cat "$markdown_report"
  elif [[ "${HAS_BREAKING_CHANGES:-false}" == "false" ]]; then
    echo "No breaking changes detected."
  fi
} >> "$GITHUB_STEP_SUMMARY"
