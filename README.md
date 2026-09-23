# Roseau Action

A GitHub Action that detects breaking changes between two versions of a Java library using [Roseau](https://github.com/alien-tools/roseau).

It compares a `baseline` version against a `current` version, then:

- fails the step when breaking changes are found (configurable),
- writes the report to the job summary,
- posts or updates a single PR comment on `pull_request` events,
- uploads JSON and Markdown reports as a workflow artifact.

Each version can be Maven coordinates (`groupId:artifactId:version`), a local JAR, or a source directory.

## Usage

### Maven

Compare the last published release against the JAR built from the current commit:

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
      issues: write
      pull-requests: read
    steps:
      - uses: actions/checkout@v6

      - run: ./mvnw --batch-mode -DskipTests package

      - uses: alien-tools/roseau-action@v2
        with:
          baseline: com.example:my-lib:1.2.0
          current: target/my-lib-1.3.0-SNAPSHOT.jar
          v2-pom: pom.xml
          roseau-version: v0.7.0
```

### Gradle

```yaml
- uses: actions/checkout@v6

- run: ./gradlew jar

- uses: alien-tools/roseau-action@v2
  with:
    baseline: com.example:my-lib:1.2.0
    current: build/libs/my-lib-1.3.0-SNAPSHOT.jar
    roseau-version: v0.7.0
```

### Against the PR's base branch

Compare source directories directly, without building or publishing anything:

```yaml
- uses: actions/checkout@v6
  with:
    path: current

- uses: actions/checkout@v6
  with:
    ref: ${{ github.event.pull_request.base.sha }}
    path: baseline

- uses: alien-tools/roseau-action@v2
  with:
    baseline: baseline/src/main/java
    current: current/src/main/java
    roseau-version: v0.7.0
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `baseline` | yes | | Baseline version: Maven coordinates, local JAR, or source directory |
| `current` | yes | | Current version: Maven coordinates, local JAR, or source directory |
| `fail-on-breaking-changes` | no | `true` | Fail the step if breaking changes are found |
| `compatibility` | no | `all` | Which breaking changes to report: `all`, `binary`, or `source` |
| `ignored` | no | | Path to a CSV file listing accepted breaking changes |
| `config` | no | | Path to a [`roseau.yaml`](https://alien-tools.github.io/roseau/stable/) configuration file |
| `classpath` | no | | Extra classpath JARs shared by both versions |
| `v1-classpath` | no | | Extra classpath JARs for the baseline version |
| `v2-classpath` | no | | Extra classpath JARs for the current version |
| `pom` | no | | `pom.xml` used to extract a classpath shared by both versions |
| `v1-pom` | no | | `pom.xml` used to extract the baseline classpath |
| `v2-pom` | no | | `pom.xml` used to extract the current classpath |
| `reports` | no | | Additional reports as comma-separated `FORMAT=PATH` pairs; formats: `CLI`, `CSV`, `HTML`, `JSON`, `MD` |
| `report-dir` | no | `roseau-reports` | Directory where the default JSON and Markdown reports are written |
| `upload-reports` | no | `true` | Upload `report-dir` as the `roseau-reports` workflow artifact |
| `comment` | no | `true` | Post or update a PR comment with the report |
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
    baseline: com.example:my-lib:1.2.0
    current: target/my-lib-1.3.0-SNAPSHOT.jar
    reports: HTML=roseau-reports/report.html,CSV=roseau-reports/report.csv
```

Artifact names must be unique within a workflow run. If you use the action more than once in a run, set `upload-reports: false` on all but one of them.

## Report-only mode

```yaml
- uses: alien-tools/roseau-action@v2
  id: roseau
  with:
    baseline: com.example:my-lib:1.2.0
    current: target/my-lib-1.3.0-SNAPSHOT.jar
    fail-on-breaking-changes: false

- if: steps.roseau.outputs.has-breaking-changes == 'true'
  run: echo "${{ steps.roseau.outputs.breaking-change-count }} breaking change(s) found"
```

## Accepted breaking changes

List intentional breaking changes in a CSV file with the same structure as a Roseau CSV report:

```yaml
- uses: alien-tools/roseau-action@v2
  with:
    baseline: com.example:my-lib:1.2.0
    current: target/my-lib-1.3.0-SNAPSHOT.jar
    ignored: .roseau/accepted-breaks.csv
```

## Permissions

For PR comments, use:

```yaml
permissions:
  contents: read
  issues: write
  pull-requests: read
```

Without PR comments (`comment: false`), `contents: read` is enough.

PR comments usually cannot be written on pull requests from forks with the default `GITHUB_TOKEN`. In that case, the action warns and continues; the compatibility check and job summary still run.

## Requirements

The action runs on GitHub-hosted Ubuntu runners. Self-hosted runners need `bash` 4.3+, `gh`, and `jq`.

## Upgrading from v1

v1 took no inputs and compared the last two commits of the checked-out repository. v2 compares two explicit versions:

- set `baseline` and `current` (see [Against the PR's base branch](#against-the-prs-base-branch) for the closest equivalent to v1),
- `report-artifact` is replaced by `reports` and `upload-reports`,
- the step fails on breaking changes by default; set `fail-on-breaking-changes: false` to only report them.
