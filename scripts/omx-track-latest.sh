#!/bin/bash
#******************************************************************************
# scripts/omx-track-latest.sh, the device follows the latest: zynthian-ui and
# zynthian-sys fast-forwarded to the newest signed omx-track/<YYYYMMDDXX> tag
# on the FreeMixer fork, the omx packages upgraded from the channel. zynthian
# is restarted only when something changed. One journal line per step. Run
# daily by omx-track-latest.timer (enabled by update_zynthian_sys.sh).
#
# The branch tip is never taken. A tag is taken only when its signature is
# good by a key in keys/track-signing-keys.asc of this checkout, read before
# anything moves, it names the repository it is for, and it fast-forwards
# what the device runs. A commit pushed to the fork without such a tag, a tag
# signed by any other key, and a device with no pinned key all leave the
# checkout where it is, with one line in the journal saying why. The key file
# itself only changes through a signed tag. Tags are made with
# scripts/omx-track-tag.sh. The apt half is unchanged: apt checks the
# channel's signed index itself.
#
# The UI keeps "a chain is playing" inside its own process and exposes it
# nowhere a unit can read, so this script cannot refuse on it. What it can
# honour is a hold file: while HOLD_FILE exists nothing is touched.
#******************************************************************************

BRANCH=${BRANCH:-vangelis}
TAG_PREFIX=omx-track/
TRACK_KEYS=${TRACK_KEYS:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/keys/track-signing-keys.asc}
FORK_URL_PATTERN=${FORK_URL_PATTERN:-FreeMixer/}
HOLD_FILE=${HOLD_FILE:-/run/omx-track-latest.hold}
ZYNTHIAN_DIR=${ZYNTHIAN_DIR:-/zynthian}
REPOS=${REPOS:-"$ZYNTHIAN_DIR/zynthian-ui $ZYNTHIAN_DIR/zynthian-sys"}
PACKAGES=${PACKAGES:-"omx-panel omx-plugins omx-plugins-clap omx-plugins-contract omx-plugins-lv2 plugin-hostd plugin-qualify omx-clap-host"}
GIT=${GIT:-git}
APT_GET=${APT_GET:-apt-get}
DPKG_QUERY=${DPKG_QUERY:-dpkg-query}
SYSTEMCTL=${SYSTEMCTL:-systemctl}

changed=0
failed=0
say() { echo "omx-track-latest: $*"; }

if [ -e "$HOLD_FILE" ]; then
	say "hold file $HOLD_FILE exists, nothing touched"
	exit 0
fi

# The remote that is the FreeMixer fork: "fork" when the checkout has one,
# else whichever remote's URL names the fork
fork_remote() {
	local repo=$1 r
	for r in fork origin $("$GIT" -C "$repo" remote); do
		if "$GIT" -C "$repo" remote get-url "$r" 2>/dev/null | grep -q "$FORK_URL_PATTERN"; then
			echo "$r"
			return 0
		fi
	done
	return 1
}

# The pinned keys, read once before any repository moves: a keyring for gpgv
# and the primary fingerprints a good signature must come from
keyring=""
pinned=""
nokey="no pinned signing key at $TRACK_KEYS"
command -v gpg >/dev/null && command -v gpgv >/dev/null || nokey="gpg and gpgv are needed to check a signature (apt-get install gnupg)"
if [ -s "$TRACK_KEYS" ] && command -v gpg >/dev/null && command -v gpgv >/dev/null; then
	keyring=$(mktemp)
	trap 'rm -f "$keyring"' EXIT
	gpg --batch --yes --dearmor <"$TRACK_KEYS" >"$keyring" 2>/dev/null || keyring=""
	pinned=$(gpg --batch --with-colons --import-options show-only --import <"$TRACK_KEYS" 2>/dev/null |
		awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}')
fi

# The commit a signed track tag points at, after checking it; nothing and a
# journal line otherwise. <repo> <name> <ref>
verified_commit() {
	local repo=$1 name=$2 ref=$3 tag body payload sig status fpr
	tag=${ref#refs/omx-track/*/}
	[ "$("$GIT" -C "$repo" cat-file -t "$ref" 2>/dev/null)" = tag ] || { say "$name: $TAG_PREFIX$tag is not an annotated tag, not taken" >&2; return 1; }
	body=$("$GIT" -C "$repo" cat-file tag "$ref")
	if ! printf '%s\n' "$body" | grep -qx "tag $TAG_PREFIX$tag" ||
		! printf '%s\n' "$body" | grep -qx 'type commit' ||
		! printf '%s\n' "$body" | grep -qx "repository: $name"; then
		say "$name: $TAG_PREFIX$tag does not name $name and itself, not taken" >&2
		return 1
	fi
	payload=$(mktemp)
	sig=$(mktemp)
	printf '%s\n' "$body" | sed '/^-----BEGIN PGP SIGNATURE-----$/,$d' >"$payload"
	printf '%s\n' "$body" | sed -n '/^-----BEGIN PGP SIGNATURE-----$/,$p' >"$sig"
	status=$(gpgv --status-fd 1 --keyring "$keyring" "$sig" "$payload" 2>/dev/null)
	rm -f "$payload" "$sig"
	fpr=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" {print $NF}')
	if [ -z "$fpr" ] || printf '%s\n' "$status" | grep -qE ' (BADSIG|ERRSIG|EXPKEYSIG|REVKEYSIG|EXPSIG) ' ||
		! printf '%s\n' "$pinned" | grep -qx "$fpr"; then
		say "$name: $TAG_PREFIX$tag has no good signature by a pinned key, not taken" >&2
		return 1
	fi
	"$GIT" -C "$repo" rev-parse "$ref^{commit}"
}

track_repo() {
	local repo=$1 name remote before after newest commit
	name=$(basename "$repo")
	if ! remote=$(fork_remote "$repo"); then
		say "$name: no remote points at the fork, skipped"
		failed=1
		return
	fi
	before=$("$GIT" -C "$repo" rev-parse HEAD)
	if [ -z "$keyring" ] || [ -z "$pinned" ]; then
		say "$name: $nokey, staying at ${before:0:9}"
		failed=1
		return
	fi
	# the fork's track tags, in a namespace of their own so no local tag is overwritten
	if ! "$GIT" -C "$repo" fetch -q --no-tags "$remote" "+refs/tags/$TAG_PREFIX*:refs/omx-track/$remote/*"; then
		say "$name: fetch from $remote failed"
		failed=1
		return
	fi
	# the newest tag that verifies; each one refused on the way is a journal line,
	# so a forged tag can neither be taken nor hide a good one behind it
	newest=""
	commit=""
	while IFS= read -r ref; do
		[ -n "$ref" ] || continue
		if commit=$(verified_commit "$repo" "$name" "$ref"); then
			newest=$ref
			break
		fi
		failed=1
	done < <("$GIT" -C "$repo" for-each-ref --format='%(refname)' "refs/omx-track/$remote/" | sort -rV)
	if [ -z "$newest" ]; then
		say "$name: no signed $TAG_PREFIX tag to take, staying at ${before:0:9}"
		return
	fi
	if [ -n "$("$GIT" -C "$repo" status --porcelain --untracked-files=no)" ]; then
		say "$name: working tree has local changes, left alone"
		failed=1
		return
	fi
	if ! "$GIT" -C "$repo" show-ref -q --verify "refs/heads/$BRANCH"; then
		"$GIT" -C "$repo" branch -q "$BRANCH" HEAD || { failed=1; return; }
	fi
	if "$GIT" -C "$repo" merge-base --is-ancestor "$commit" "$BRANCH"; then
		say "$name: already at ${before:0:9} (signed ${newest##*/})"
		return
	fi
	if ! "$GIT" -C "$repo" merge-base --is-ancestor "$BRANCH" "$commit"; then
		say "$name: $BRANCH has local commits ${newest##*/} lacks, left alone"
		failed=1
		return
	fi
	"$GIT" -C "$repo" checkout -q "$BRANCH" && "$GIT" -C "$repo" merge -q --ff-only "$commit" || {
		say "$name: fast-forward failed"
		failed=1
		return
	}
	after=$("$GIT" -C "$repo" rev-parse HEAD)
	say "$name: ${before:0:9} -> ${after:0:9} (signed ${newest##*/})"
	changed=1
}

versions() {
	local p
	for p in $PACKAGES; do
		"$DPKG_QUERY" -W -f '${Package} ${Version}\n' "$p" 2>/dev/null
	done
}

for repo in $REPOS; do
	track_repo "$repo"
done

if "$APT_GET" update -qq; then
	installed=$(versions | awk '{print $1}' | tr '\n' ' ')
	vbefore=$(versions)
	if [ -n "$installed" ] && "$APT_GET" install -y -qq --only-upgrade $installed >/dev/null; then
		vafter=$(versions)
		if [ "$vbefore" = "$vafter" ]; then
			say "packages: no change"
		else
			say "packages: $(diff <(echo "$vbefore") <(echo "$vafter") | grep '^>' | sed 's/^> //' | tr '\n' ';')"
			changed=1
		fi
	else
		say "packages: upgrade failed"
		failed=1
	fi
else
	say "packages: apt-get update failed"
	failed=1
fi

if [ "$changed" = 1 ]; then
	say "something changed, restarting zynthian"
	"$SYSTEMCTL" restart zynthian || failed=1
else
	say "nothing changed, zynthian left running"
fi
exit $failed
