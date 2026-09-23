# Roseau Action

A GitHub Action that detects breaking changes between two versions of a Java library using [Roseau](https://github.com/alien-tools/roseau).

It compares a baseline version of your library against its current version, then:

- fails the step when breaking changes are found (configurable),
- writes the report to the job summary,
- posts or updates a single PR comment on `pull_request` events,
- marks each breaking change on the lines of the PR diff, with inline review comments (or annotations on pull requests from forks),
- uploads JSON and Markdown reports as a workflow artifact.

## Usage

```yaml
name: API compatibility

on:
  pull_request:
  push:
    branches: [main]

jobs:
  roseau:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v6

      - uses: alien-tools/roseau-action@v2
        with:
          current: src/main/java
          pom: pom.xml
          roseau-version: v0.7.0
```

`current` is the version to check: here, the sources of the checked-out commit. Unless told otherwise, the baseline is the same directory before the change:

| Event | Baseline |
|---|---|
| `pull_request` | The base commit of the pull request |
| `push` | The previous commit of the branch (`github.event.before`) |

The job summary and the PR comment always state which versions were compared. The action fetches the baseline commit itself, so the default shallow `actions/checkout` is enough. With `pom`, each version is analyzed with its own `pom.xml`.

### Choosing the baseline

To compare against something else, set one of:

- `baseline-ref`: a git tag, branch, or commit, for instance the last release:

  ```yaml
  - uses: alien-tools/roseau-action@v2
    with:
      current: src/main/java
      baseline-ref: v1.2.0
  ```

- `baseline`: Maven coordinates of a published release, a JAR, or a source directory:

  ```yaml
  - uses: alien-tools/roseau-action@v2
    with:
      current: src/main/java
      baseline: com.example:my-lib:1.2.0
  ```

To use different baselines for pull requests and pushes, use an expression. For instance, to check pull requests against their base branch, and `main` against the last release, without failing on `main`:

```yaml
- uses: alien-tools/roseau-action@v2
  with:
    current: src/main/java
    pom: pom.xml
    baseline-ref: ${{ github.event_name == 'push' && 'v1.2.0' || '' }}
    fail-on-breaking-changes: ${{ github.event_name == 'pull_request' }}
```

### Comparing JARs

`current` can also be a JAR built by your workflow. A JAR cannot be rebuilt at a git ref, so set `baseline` to the Maven coordinates of a release (or to another JAR):

```yaml
- uses: actions/checkout@v6

- run: ./mvnw --batch-mode -DskipTests package   # or: ./gradlew jar

- uses: alien-tools/roseau-action@v2
  with:
    baseline: com.example:my-lib:1.2.0
    current: target/my-lib-1.3.0-SNAPSHOT.jar
    v2-pom: pom.xml
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `current` | yes | | Current version: source directory, local JAR, or Maven coordinates |
| `baseline-ref` | no | PR base commit, or previous commit on push | Git tag, branch, or commit at which `current` is the baseline |
| `baseline` | no | | Baseline version: Maven coordinates, local JAR, or source directory; replaces `baseline-ref` |
| `fail-on-breaking-changes` | no | `true` | Fail the step if breaking changes are found |
| `compatibility` | no | `all` | Which breaking changes to report: `all`, `binary`, or `source` |
| `ignored` | no | | Path to a CSV file listing accepted breaking changes |
| `config` | no | | Path to a [`roseau.yaml`](https://alien-tools.github.io/roseau/stable/) configuration file |
| `classpath` | no | | Extra classpath JARs shared by both versions |
| `v1-classpath` | no | | Extra classpath JARs for the baseline version |
| `v2-classpath` | no | | Extra classpath JARs for the current version |
| `pom` | no | | `pom.xml` used to extract the classpath; read from each version when the baseline is a git ref |
| `v1-pom` | no | | `pom.xml` used to extract the baseline classpath |
| `v2-pom` | no | | `pom.xml` used to extract the current classpath |
| `reports` | no | | Additional reports as comma-separated `FORMAT=PATH` pairs; formats: `CLI`, `CSV`, `HTML`, `JSON`, `MD` |
| `report-dir` | no | `roseau-reports` | Directory where the default JSON and Markdown reports are written |
| `upload-reports` | no | `true` | Upload `report-dir` as the `roseau-reports` workflow artifact |
| `comment` | no | `true` | Post or update a PR comment with the report |
| `inline-comments` | no | `true` | Comment each breaking change on the lines of the PR diff; requires `comment` |
| `annotations` | no | `auto` | Annotate breaking changes on the lines of the PR diff: `auto` (only those without an inline comment), `true`, or `false` |
| `java-version` | no | `25` | JDK version used to run Roseau |
| `roseau-version` | no | `latest` | Roseau release to use, such as `v0.7.0`, or `latest` |

`roseau-version: latest` is convenient, but pinning a Roseau release is recommended for reproducible CI.

Classpath inputs are passed through to Roseau. Providing the dependencies of a JAR or source directory (for example with `v2-pom`) gives more accurate results. Maven coordinates resolve their own dependencies.

## Outputs

| Output | Description |
|---|---|
| `has-breaking-changes` | `true` or `false` |
| `breaking-change-count` | Number of breaking changes detected |
| `report-dir` | Directory containing generated reports |
| `json-report` | Path to the generated JSON report |
| `markdown-report` | Path to the generated Markdown report |

## Reports

The action always generates:

```text
roseau-reports/report.json
roseau-reports/report.md
```

By default, the report directory is uploaded as a workflow artifact named `roseau-reports`. Add extra formats with `reports`, and write them inside `report-dir` so they are uploaded too:

```yaml
- uses: alien-tools/roseau-action@v2
  with:
    current: src/main/java
    reports: HTML=roseau-reports/report.html,CSV=roseau-reports/report.csv
```

Artifact names must be unique within a workflow run. If you use the action more than once in a run, set `upload-reports: false` on all but one of them.

## Report-only mode

```yaml
- uses: alien-tools/roseau-action@v2
  id: roseau
  with:
    current: src/main/java
    fail-on-breaking-changes: false

- if: steps.roseau.outputs.has-breaking-changes == 'true'
  run: echo "${{ steps.roseau.outputs.breaking-change-count }} breaking change(s) found"
```

## Accepted breaking changes

List intentional breaking changes in a CSV file with the same structure as a Roseau CSV report:

```yaml
- uses: alien-tools/roseau-action@v2
  with:
    current: src/main/java
    ignored: .roseau/accepted-breaks.csv
```

## Breaking changes in the diff

On pull requests, the action marks each breaking change once on the lines of the diff:

- **inline review comments** are the default. They are posted as a single review, can be replied to and resolved, and are updated in place: comments for fixed breaking changes are deleted, and a new push only adds comments for new breaking changes. They require the `pull-requests: write` permission.
- **annotations** are the fallback, when inline comments cannot be posted (pull requests from forks, `comment: false`, or `inline-comments: false`). They need no permissions and appear in the "Files changed" tab and in the check run, but only on the new side of the diff, and GitHub shows at most 10 of each level per step.

With `annotations: auto` (the default), breaking changes outside the diff are also annotated in their unchanged file, since inline comments cannot mark them. Use `annotations: true` to always annotate every breaking change, or `false` to never annotate.

Breaking changes are anchored to the most precise line of the diff:

| Breaking change | Line |
|---|---|
| Removed symbol (method, field, type, constructor…) | Its deleted declaration line |
| Modified symbol (return type, modifiers, thrown exceptions…) | Its new declaration line, or its deleted old line with Roseau releases that do not report new locations |
| Added symbol (e.g. a new abstract method in an interface) | Its added declaration line, or the declaration of its type with Roseau releases that do not report new locations |

Breaking changes that are not on a line of the diff, for instance a subclass losing an inherited method, are annotated on their unchanged file and listed in the PR comment.

Annotations are errors when `fail-on-breaking-changes` is `true`, and warnings otherwise.

## Permissions

For PR comments and inline comments, use:

```yaml
permissions:
  contents: read
  pull-requests: write
```

Without PR comments (`comment: false`, which also disables inline comments), `contents: read` is enough.

Only one use of the action per pull request should post comments: when several jobs check the same pull request, set `comment: false` on all but one of them.

Pull requests from forks get a read-only `GITHUB_TOKEN`, so comments cannot be written. In that case, the action warns and continues; the compatibility check, the annotations, and the job summary still run.

## Requirements

The action runs on GitHub-hosted Ubuntu runners. Self-hosted runners need `bash` 4.3+, `git`, `python3` 3.9+, `gh`, and `jq`.

## Upgrading from v1

v1 took no inputs and compared the last two commits of the checked-out repository. v2 does the same on `push` events, and compares pull requests against their base commit:

- set `current` to your source directory, such as `src/main/java`, and optionally [choose another baseline](#choosing-the-baseline),
- `report-artifact` is replaced by `reports` and `upload-reports`,
- the step fails on breaking changes by default; set `fail-on-breaking-changes: false` to only report them.
