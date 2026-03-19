# Roseau Action

A GitHub Action that detects breaking changes between two versions of a Java library using [Roseau](https://github.com/alien-tools/roseau).

## Usage

```yaml
jobs:
  api-compatibility:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write  # Required for PR comments
    steps:
      - uses: actions/checkout@v6
      - run: mvn --batch-mode -DskipTests package

      - uses: alien-tools/roseau-action@v1
        with:
          v1: com.example:my-lib:1.2.0
          v2: target/my-lib-1.3.0-SNAPSHOT.jar
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `v1` | yes | | Baseline version: Maven coordinates (`g:a:v`), local JAR, or source directory |
| `v2` | yes | | Current version: Maven coordinates (`g:a:v`), local JAR, or source directory |
| `fail-on-bc` | no | `true` | Fail the step if breaking changes are found |
| `binary-only` | no | `false` | Only report binary-breaking changes |
| `source-only` | no | `false` | Only report source-breaking changes |
| `ignored` | no | | Path to a CSV file listing accepted breaking changes |
| `comment` | no | `true` | Post/update a PR comment with the report |
| `reports` | no | | Comma-separated `FORMAT=PATH` pairs (e.g. `HTML=report.html,CSV=report.csv`) |
| `classpath` | no | | Extra classpath JARs (colon-separated) |
| `java-version` | no | `25` | JDK version to set up |
| `roseau-version` | no | `latest` | Roseau release version (e.g. `v0.6.0`) |

## Outputs

| Output | Description |
|---|---|
| `has-breaking-changes` | `true` or `false` |
| `breaking-change-count` | Number of breaking changes detected |
| `report-path` | Path to the generated JSON report |

## Examples

### Compare a built JAR against the latest release

```yaml
- uses: alien-tools/roseau-action@v1
  with:
    v1: com.example:my-lib:1.2.0
    v2: target/my-lib-1.3.0-SNAPSHOT.jar
    reports: HTML=roseau-report.html
```

### Source-only check with accepted breaks

```yaml
- uses: alien-tools/roseau-action@v1
  with:
    v1: com.example:my-lib:1.2.0
    v2: target/my-lib-1.3.0-SNAPSHOT.jar
    source-only: true
    ignored: .roseau/accepted-breaks.csv
```

### Conditional steps based on results

```yaml
- uses: alien-tools/roseau-action@v1
  id: roseau
  with:
    v1: com.example:my-lib:1.2.0
    v2: target/my-lib-1.3.0-SNAPSHOT.jar
    fail-on-bc: false

- if: steps.roseau.outputs.has-breaking-changes == 'true'
  run: echo "${{ steps.roseau.outputs.breaking-change-count }} breaking change(s) found"
```
