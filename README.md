# Roseau Action

A GitHub Action that detects breaking changes between two versions of a Java library using [Roseau](https://github.com/alien-tools/roseau).

## Maven

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

      - uses: alien-tools/roseau-action@v1
        with:
          baseline: com.example:my-lib:1.2.0
          current: target/my-lib-1.3.0-SNAPSHOT.jar
          roseau-version: v0.6.0
```

## Gradle

```yaml
- uses: actions/checkout@v6

- run: ./gradlew jar

- uses: alien-tools/roseau-action@v1
  with:
    baseline: com.example:my-lib:1.2.0
    current: build/libs/my-lib-1.3.0-SNAPSHOT.jar
    classpath: build/libs/dependency.jar
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `baseline` | yes* | | Baseline version: Maven coordinates, local JAR, or source directory |
| `current` | yes* | | Current version: Maven coordinates, local JAR, or source directory |
| `v1` | yes* | | Legacy alias for `baseline` |
| `v2` | yes* | | Legacy alias for `current` |
| `fail-on-breaking-changes` | no | `true` | Fail the step if breaking changes are found |
| `fail-on-bc` | no | `true` | Legacy alias for `fail-on-breaking-changes` |
| `compatibility` | no | `all` | Compatibility mode: `all`, `binary`, or `source` |
| `ignored` | no | | Path to a CSV file listing accepted breaking changes |
| `config` | no | | Path to a `roseau.yaml` configuration file |
| `classpath` | no | | Extra classpath entries shared by both versions |
| `v1-classpath` | no | | Extra classpath entries for the baseline version |
| `v2-classpath` | no | | Extra classpath entries for the current version |
| `pom` | no | | POM used to extract a shared classpath |
| `v1-pom` | no | | POM used to extract the baseline classpath |
| `v2-pom` | no | | POM used to extract the current classpath |
| `reports` | no | | Comma-separated `FORMAT=PATH` pairs, such as `HTML=roseau-reports/report.html` |
| `report-dir` | no | `roseau-reports` | Directory where default JSON and Markdown reports are written |
| `upload-reports` | no | `true` | Upload generated reports as the `roseau-reports` workflow artifact |
| `comment` | no | `true` | Post or update a PR comment with the report |
| `java-version` | no | `25` | JDK version used to run Roseau |
| `roseau-version` | no | `latest` | Roseau release version, for example `v0.6.0` |

`*` Provide exactly one baseline input, either `baseline` or `v1`, and exactly one current input, either `current` or `v2`.

`roseau-version: latest` is convenient, but pinning a Roseau release is recommended for reproducible CI.

## Outputs

| Output | Description |
|---|---|
| `has-breaking-changes` | `true` or `false` |
| `breaking-change-count` | Number of breaking changes detected |
| `report-dir` | Directory containing generated reports |
| `json-report` | Path to the generated JSON report |
| `markdown-report` | Path to the generated Markdown report |
| `report-path` | Legacy alias for `json-report` |

## Reports

The action always generates:

```text
roseau-reports/report.json
roseau-reports/report.md
```

By default, the full report directory is uploaded as a workflow artifact named `roseau-reports`. Add extra formats with `reports`:

```yaml
- uses: alien-tools/roseau-action@v1
  with:
    baseline: com.example:my-lib:1.2.0
    current: target/my-lib-1.3.0-SNAPSHOT.jar
    reports: HTML=roseau-reports/report.html,CSV=roseau-reports/report.csv
```

## Non-Failing Mode

```yaml
- uses: alien-tools/roseau-action@v1
  id: roseau
  with:
    baseline: com.example:my-lib:1.2.0
    current: target/my-lib-1.3.0-SNAPSHOT.jar
    fail-on-breaking-changes: false

- if: steps.roseau.outputs.has-breaking-changes == 'true'
  run: echo "${{ steps.roseau.outputs.breaking-change-count }} breaking change(s) found"
```

## Accepted Breaks

```yaml
- uses: alien-tools/roseau-action@v1
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

For workflows without PR comments, use:

```yaml
permissions:
  contents: read
```

PR comments usually cannot be written on fork pull requests with the default `GITHUB_TOKEN`. In that case, the action warns and continues; the compatibility check and job summary still run.
