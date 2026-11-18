#!/usr/bin/env bash
# Fetch the bats test framework into tests/.deps, pinned by commit.
set -Eeuo pipefail

DEPS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/.deps

# name  repository                                      tag     commit
DEPS=(
	"bats-core    https://github.com/bats-core/bats-core.git     v1.14.0 eb7f42f8d608ac693d7a4b67474f6714ea68cfc5"
	"bats-support https://github.com/bats-core/bats-support.git  v0.3.0  24a72e14349690bcbf7c151b9d2d1cdd32d36eb1"
	"bats-assert  https://github.com/bats-core/bats-assert.git   v2.2.4  f1e9280eaae8f86cbe278a687e6ba755bc802c1a"
)

mkdir -p "$DEPS_DIR"
for dep in "${DEPS[@]}"; do
	read -r name repo tag commit <<<"$dep"
	dir=$DEPS_DIR/$name
	if [[ -d $dir/.git && $(git -C "$dir" rev-parse HEAD) == "$commit" ]]; then
		continue
	fi
	rm -rf -- "$dir"
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$repo" "$dir"
	actual=$(git -C "$dir" rev-parse HEAD)
	if [[ $actual != "$commit" ]]; then
		echo "error: $name $tag is $actual, expected $commit (tag moved?)" >&2
		exit 1
	fi
done
echo "test dependencies ready in $DEPS_DIR" >&2
