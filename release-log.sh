#!/bin/sh
# Resolve current upstream source once; the workflow builds these exact commits.
set -eu
version=${1:?Usage: ./release-log.sh X.Y.Z}
printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || exit 1
source_sha=$(gh api repos/codag-megalith/codag/commits/main --jq .sha)
dependency_sha=$(gh api repos/codag-megalith/codag-drain/commits/master --jq .sha)
printf 'Release log-v%s from source %s and dependency %s\n' "$version" "$source_sha" "$dependency_sha"
gh workflow run log-engine.yml --repo codag-megalith/codag-releases \
    -f "version=$version" -f "source_sha=$source_sha" -f "dependency_sha=$dependency_sha"
printf 'Track: https://github.com/codag-megalith/codag-releases/actions/workflows/log-engine.yml\n'
