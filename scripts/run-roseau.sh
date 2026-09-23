#!/usr/bin/env bash
set -euo pipefail

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_boolean() {
  local name="$1"
  local value="$2"

  if [[ -n "$value" && "$value" != "true" && "$value" != "false" ]]; then
    echo "::error::$name must be 'true' or 'false'"
    exit 1
  fi
}

require_report_spec() {
  local spec="$1"
  local format="${spec%%=*}"
  local path="${spec#*=}"

  if [[ "$spec" != *=* || -z "$format" || -z "$path" ]]; then
    echo "::error::Invalid report specification '$spec'. Expected FORMAT=PATH"
    exit 1
  fi

  case "$format" in
    CLI|CSV|HTML|JSON|MD) ;;
    *)
      echo "::error::Invalid report format '$format'. Expected CLI, CSV, HTML, JSON, or MD"
      exit 1
      ;;
  esac
}

baseline="${INPUT_BASELINE:-}"
current="${INPUT_CURRENT:-}"

if [[ -z "$baseline" ]]; then
  echo "::error::Missing required input: baseline"
  exit 1
fi

if [[ -z "$current" ]]; then
  echo "::error::Missing required input: current"
  exit 1
fi

fail_on_breaking_changes="${INPUT_FAIL_ON_BREAKING_CHANGES:-true}"
require_boolean "fail-on-breaking-changes" "$fail_on_breaking_changes"

compatibility="${INPUT_COMPATIBILITY:-all}"
case "$compatibility" in
  all|binary|source) ;;
  *)
    echo "::error::compatibility must be 'all', 'binary', or 'source'"
    exit 1
    ;;
esac

report_dir="${INPUT_REPORT_DIR:-roseau-reports}"
if [[ -z "$report_dir" ]]; then
  report_dir="roseau-reports"
fi
mkdir -p "$report_dir"

json_report="$report_dir/report.json"
markdown_report="$report_dir/report.md"

cmd=(java -jar "$ROSEAU_JAR" --diff --v1 "$baseline" --v2 "$current" --plain --fail-on-bc)
cmd+=(--report "JSON=$json_report")
cmd+=(--report "MD=$markdown_report")

case "$compatibility" in
  binary) cmd+=(--binary-only) ;;
  source) cmd+=(--source-only) ;;
esac

[[ -n "${INPUT_IGNORED:-}" ]] && cmd+=(--ignored "$INPUT_IGNORED")
[[ -n "${INPUT_CONFIG:-}" ]] && cmd+=(--config "$INPUT_CONFIG")
[[ -n "${INPUT_CLASSPATH:-}" ]] && cmd+=(--classpath "$INPUT_CLASSPATH")
[[ -n "${INPUT_V1_CLASSPATH:-}" ]] && cmd+=(--v1-classpath "$INPUT_V1_CLASSPATH")
[[ -n "${INPUT_V2_CLASSPATH:-}" ]] && cmd+=(--v2-classpath "$INPUT_V2_CLASSPATH")
[[ -n "${INPUT_POM:-}" ]] && cmd+=(--pom "$INPUT_POM")
[[ -n "${INPUT_V1_POM:-}" ]] && cmd+=(--v1-pom "$INPUT_V1_POM")
[[ -n "${INPUT_V2_POM:-}" ]] && cmd+=(--v2-pom "$INPUT_V2_POM")

if [[ -n "${INPUT_REPORTS:-}" ]]; then
  IFS=',' read -ra extra_reports <<< "$INPUT_REPORTS"
  for raw_report in "${extra_reports[@]}"; do
    report="$(trim "$raw_report")"
    [[ -z "$report" ]] && continue
    require_report_spec "$report"
    cmd+=(--report "$report")
  done
fi

echo "::group::Roseau output"
set +e
"${cmd[@]}"
exit_code=$?
set -e
echo "::endgroup::"

case "$exit_code" in
  0)
    has_breaking_changes=false
    ;;
  1)
    has_breaking_changes=true
    ;;
  *)
    echo "::error::Roseau encountered an error"
    exit "$exit_code"
    ;;
esac

if [[ ! -f "$json_report" ]]; then
  echo "::error::Roseau did not generate the expected JSON report: $json_report"
  exit 1
fi

count="$(jq 'length' "$json_report")"

{
  echo "has-breaking-changes=$has_breaking_changes"
  echo "breaking-change-count=$count"
  echo "report-dir=$report_dir"
  echo "json-report=$json_report"
  echo "markdown-report=$markdown_report"
  echo "fail-on-breaking-changes=$fail_on_breaking_changes"
} >> "$GITHUB_OUTPUT"
