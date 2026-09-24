#!/usr/bin/env bash
set -euo pipefail

roseau_version="${ROSEAU_VERSION:-latest}"

if [[ "$roseau_version" == "latest" ]]; then
  tag="$(gh release view --repo alien-tools/roseau --json tagName -q .tagName)"
else
  tag="$roseau_version"
fi

echo "Downloading Roseau $tag"

version="${tag#v}"
if [[ -n "$version" && "$version" != "$tag" ]]; then
  pattern="roseau-$version.jar"
else
  pattern="roseau-*.jar"
fi

roseau_dir="$RUNNER_TEMP/roseau"
mkdir -p "$roseau_dir"

if ! gh release download "$tag" --repo alien-tools/roseau --pattern "$pattern" --dir "$roseau_dir" --clobber; then
  echo "::error::Could not download Roseau release matching '$pattern' from tag '$tag'"
  exit 1
fi

shopt -s nullglob
jars=("$roseau_dir"/roseau-*.jar)
shopt -u nullglob

if (( ${#jars[@]} == 0 )); then
  echo "::error::No Roseau JAR was downloaded for tag '$tag'"
  exit 1
fi

echo "jar=${jars[0]}" >> "$GITHUB_OUTPUT"
echo "tag=$tag" >> "$GITHUB_OUTPUT"
