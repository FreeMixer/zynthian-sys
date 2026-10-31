#!/bin/bash
#******************************************************************************
# scripts/omx-track-tag.sh, publish what devices following the fork may take:
# a signed annotated tag omx-track/<YYYYMMDDXX> (XX the day's serial) on a
# commit of zynthian-ui or zynthian-sys, which scripts/omx-track-latest.sh
# verifies against keys/track-signing-keys.asc before it moves a device.
#
#   omx-track-tag.sh <checkout> [<commit>] [--key <key id>] [--push <remote>]
#
# <commit> defaults to the checkout's vangelis. The tag message names the
# repository, read from the URL of the remote that points at the FreeMixer fork
# (or --name): a device refuses a tag naming another.
# The key defaults to git's user.signingkey; it must be one the key file
# pins, or devices will not take the tag.
#******************************************************************************
set -euo pipefail

usage() { echo "usage: $0 <checkout> [<commit>] [--key <key id>] [--push <remote>] [--name <repository>]" >&2; exit 2; }
repo=""
commit=""
key=""
push=""
name=""
while [ $# -gt 0 ]; do
	case "$1" in
		--key) key=${2:?}; shift 2 ;;
		--push) push=${2:?}; shift 2 ;;
		--name) name=${2:?}; shift 2 ;;
		-*) usage ;;
		*) if [ -z "$repo" ]; then repo=$1; elif [ -z "$commit" ]; then commit=$1; else usage; fi; shift ;;
	esac
done
[ -n "$repo" ] || usage
if [ -z "$name" ]; then
	for r in fork origin $(git -C "$repo" remote); do
		url=$(git -C "$repo" remote get-url "$r" 2>/dev/null) || continue
		case $url in *FreeMixer/*) name=$(basename "${url%.git}"); break ;; esac
	done
fi
[ -n "$name" ] || { echo "no remote points at the FreeMixer fork: pass --name" >&2; exit 1; }
commit=$(git -C "$repo" rev-parse --verify "${commit:-vangelis}^{commit}")
key=${key:-$(git -C "$repo" config user.signingkey || true)}
[ -n "$key" ] || { echo "no signing key: pass --key or set user.signingkey" >&2; exit 1; }

day=$(date -u +%Y%m%d)
serial=1
while git -C "$repo" rev-parse -q --verify "refs/tags/omx-track/$day$(printf '%02d' "$serial")" >/dev/null ||
	{ [ -n "$push" ] && git -C "$repo" ls-remote --exit-code --tags "$push" "omx-track/$day$(printf '%02d' "$serial")" >/dev/null; }; do
	serial=$((serial + 1))
done
tag=omx-track/$day$(printf '%02d' "$serial")

git -C "$repo" tag -s -u "$key" -m "repository: $name" -m "Devices following the fork take $(git -C "$repo" rev-parse --short "$commit")." "$tag" "$commit"
git -C "$repo" verify-tag "$tag" >/dev/null 2>&1 || { git -C "$repo" tag -d "$tag" >/dev/null; echo "the new tag does not verify, deleted" >&2; exit 1; }
echo "$tag $commit"
if [ -n "$push" ]; then
	git -C "$repo" push -q "$push" "refs/tags/$tag"
	echo "pushed $tag to $push"
fi
