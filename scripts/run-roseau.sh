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

error() {
  echo "::error::$1"
  exit 1
}

relative_path() {
  python3 -c 'import os, sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' "$1" "$2"
}

# Checks out $current as it is at a git ref, in a worktree, and points $baseline at it
checkout_baseline() {
  local ref="$1" current_dir root sha
  [[ "$current" != *.jar ]] || error "A JAR cannot be compared with a git ref; set baseline to Maven coordinates or a JAR instead"
  [[ -e "$current" ]] || error "current must be a path of the repository to be compared with a git ref: '$current' does not exist"

  current_dir="$current"
  [[ -d "$current_dir" ]] || current_dir="$(dirname "$current")"
  root="$(git -C "$current_dir" rev-parse --show-toplevel 2>/dev/null)" \
    || error "'$current' is not in a git repository; check it out with actions/checkout first"

  echo "Fetching baseline $ref"
  git -C "$root" fetch --quiet --no-tags --depth=1 origin "$ref" \
    || error "Could not fetch baseline ref '$ref' from origin"
  sha="$(git -C "$root" rev-parse FETCH_HEAD)"
  worktree="$RUNNER_TEMP/roseau-baseline"
  git -C "$root" worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  git -C "$root" worktree add --quiet --detach "$worktree" "$sha"

  baseline="$worktree/$(relative_path "$current" "$root")"
  [[ -e "$baseline" ]] || error "'$current' does not exist at baseline ref '$ref' ($sha)"

  # Each version is built with its own pom.xml
  if [[ -n "${INPUT_POM:-}" && -z "${INPUT_V1_POM:-}${INPUT_V2_POM:-}" ]]; then
    v2_pom="$INPUT_POM"
    v1_pom="$worktree/$(relative_path "$INPUT_POM" "$root")"
    [[ -f "$v1_pom" ]] || v1_pom="$INPUT_POM"
    pom=""
  fi
  baseline_label="$2 (\`${sha:0:7}\`)"
}

baseline="${INPUT_BASELINE:-}"
baseline_ref="${INPUT_BASELINE_REF:-}"
current="${INPUT_CURRENT:-}"
pom="${INPUT_POM:-}"
v1_pom="${INPUT_V1_POM:-}"
v2_pom="${INPUT_V2_POM:-}"

[[ -n "$current" ]] || error "Missing required input: current"
[[ -z "$baseline" || -z "$baseline_ref" ]] || error "Use either 'baseline' or 'baseline-ref', not both"

if [[ -n "$baseline_ref" ]]; then
  checkout_baseline "$baseline_ref" "\`$baseline_ref\`"
elif [[ -n "$baseline" ]]; then
  baseline_label="\`$baseline\`"
else
  case "${EVENT_NAME:-}" in
    pull_request)
      checkout_baseline "$PR_BASE_SHA" "the base of this pull request"
      ;;
    push)
      [[ -n "${PUSH_BEFORE:-}" && "$PUSH_BEFORE" != 0000000000000000000000000000000000000000 ]] \
        || error "This push has no previous commit (e.g., a new branch); set 'baseline' or 'baseline-ref'"
      checkout_baseline "$PUSH_BEFORE" "the previous commit"
      ;;
    *)
      error "Missing input: 'baseline' or 'baseline-ref' (they only default on pull_request and push events)"
      ;;
  esac
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
echo "**Baseline:** $baseline_label · **Current:** \`$current\`" > "$report_dir/comparison.md"

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
[[ -n "$pom" ]] && cmd+=(--pom "$pom")
[[ -n "$v1_pom" ]] && cmd+=(--v1-pom "$v1_pom")
[[ -n "$v2_pom" ]] && cmd+=(--v2-pom "$v2_pom")

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
