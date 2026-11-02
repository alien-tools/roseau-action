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

# Finds the repository of $current, and the path of $current in it
locate_current() {
  local current_dir="$current"
  [[ -d "$current_dir" ]] || current_dir="$(dirname "$current")"
  root="$(git -C "$current_dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  current_path="$(relative_path "$current" "$root")"
}

# Prints the SHA of a commit or ref of origin, and fetches it unless it is already there.
# Only fetches one commit in shallow clones, so that full clones keep their history.
fetch_commit() {
  local ref="$1" fetch=(fetch --quiet --no-tags)
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && git -C "$root" cat-file -e "$ref^{commit}" 2>/dev/null; then
    echo "$ref"
    return
  fi
  [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && fetch+=(--depth=1)
  git -C "$root" "${fetch[@]}" origin "$ref" || return 1
  git -C "$root" rev-parse FETCH_HEAD
}

# Prints the merge base of two commits: with git in full clones, or else with the GitHub API
merge_base() {
  if [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == false ]] \
    && git -C "$root" merge-base "$1" "$2" 2>/dev/null; then
    return
  fi
  [[ -n "${GITHUB_REPOSITORY:-}" ]] \
    && gh api "repos/$GITHUB_REPOSITORY/compare/$1...$2" --jq .merge_base_commit.sha 2>/dev/null
}

add_worktree() {
  local sha="$1" worktree="$2"
  git -C "$root" worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  git -C "$root" worktree add --quiet --detach "$worktree" "$sha"
}

# Prints the path of a repository file in a worktree, or the file itself if the worktree does not have it
in_worktree() {
  local path="$1" worktree="$2"
  if [[ -n "$worktree" && -e "$worktree/$(relative_path "$path" "$root")" ]]; then
    echo "$worktree/$(relative_path "$path" "$root")"
  else
    echo "$path"
  fi
}

# Checks out $current as it is at the head of the pull request, in a worktree, and points $current at it
checkout_head() {
  local sha
  echo "Fetching the head of this pull request $PR_HEAD_SHA"
  sha="$(fetch_commit "$PR_HEAD_SHA")" || error "Could not fetch the head of this pull request ($PR_HEAD_SHA) from origin"
  current_worktree="$RUNNER_TEMP/roseau-current"
  add_worktree "$sha" "$current_worktree"
  current="$current_worktree/$current_path"
  [[ -e "$current" ]] || error "'$INPUT_CURRENT' does not exist at the head of this pull request ($sha)"
  current_label="\`$INPUT_CURRENT\` at the head of this pull request (\`${sha:0:7}\`)"
}

# Checks out $current as it is at a git ref, in a worktree, and points $baseline at it
checkout_baseline() {
  local ref="$1" sha worktree
  [[ "$current" != *.jar ]] || error "A JAR cannot be compared with a git ref; set baseline to Maven coordinates or a JAR instead"
  [[ -e "$current" ]] || error "current must be a path of the repository to be compared with a git ref: '$current' does not exist"
  [[ -n "$root" ]] || error "'$current' is not in a git repository; check it out with actions/checkout first"

  echo "Fetching baseline $ref"
  sha="$(fetch_commit "$ref")" || error "Could not fetch baseline ref '$ref' from origin"
  worktree="$RUNNER_TEMP/roseau-baseline"
  add_worktree "$sha" "$worktree"

  baseline="$worktree/$current_path"
  [[ -e "$baseline" ]] || error "'$INPUT_CURRENT' does not exist at baseline ref '$ref' ($sha)"

  # Each version is built with its own pom.xml
  if [[ -n "${INPUT_POM:-}" && -z "${INPUT_V1_POM:-}${INPUT_V2_POM:-}" ]]; then
    v1_pom="$(in_worktree "$INPUT_POM" "$worktree")"
    v2_pom="$(in_worktree "$INPUT_POM" "$current_worktree")"
    pom=""
  fi
  baseline_label="$2 (\`${sha:0:7}\`)"
}

# Compares the head of the pull request with its merge base, as in its "Files changed" tab
compare_pull_request() {
  local merge_base_sha
  if [[ -n "$baseline$baseline_ref" ]]; then
    echo "::notice::Pull requests are compared with their merge base; 'baseline' and 'baseline-ref' only apply to other events"
  fi
  if merge_base_sha="$(merge_base "$PR_BASE_SHA" "$PR_HEAD_SHA")" && [[ "$merge_base_sha" =~ ^[0-9a-f]{40}$ ]]; then
    checkout_head
    checkout_baseline "$merge_base_sha" "the merge base of this pull request"
  else
    echo "::warning::Could not find the merge base of this pull request; comparing the merge commit with the base commit instead, so breaking changes may not be marked on the right lines of the diff"
    checkout_baseline "$PR_BASE_SHA" "the base of this pull request"
  fi
}

baseline="${INPUT_BASELINE:-}"
baseline_ref="${INPUT_BASELINE_REF:-}"
current="${INPUT_CURRENT:-}"
current_label="\`$current\`"
current_worktree=""
root=""
pom="${INPUT_POM:-}"
v1_pom="${INPUT_V1_POM:-}"
v2_pom="${INPUT_V2_POM:-}"

[[ -n "$current" ]] || error "Missing required input: current"
[[ -z "$baseline" || -z "$baseline_ref" ]] || error "Use either 'baseline' or 'baseline-ref', not both"

[[ "$current" != *.jar && -e "$current" ]] && locate_current || true

# Pull requests define their own baseline: sources tracked by git are compared at the merge base and at the head of
# the pull request. Other versions, such as JARs or generated sources, are compared with the given baseline.
if [[ "${EVENT_NAME:-}" == pull_request && -n "$root" ]] \
  && git -C "$root" ls-files --error-unmatch -- "$current_path" > /dev/null 2>&1; then
  compare_pull_request
elif [[ -n "$baseline_ref" ]]; then
  checkout_baseline "$baseline_ref" "\`$baseline_ref\`"
elif [[ -n "$baseline" ]]; then
  baseline_label="\`$baseline\`"
else
  case "${EVENT_NAME:-}" in
    pull_request)
      error "'$INPUT_CURRENT' is not a source directory tracked by git, so it cannot be compared with the merge base of this pull request; set 'baseline'"
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
echo "**Baseline:** $baseline_label · **Current:** $current_label" > "$report_dir/comparison.md"

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
  echo "baseline-description=${baseline_label//\`/}"
} >> "$GITHUB_OUTPUT"
