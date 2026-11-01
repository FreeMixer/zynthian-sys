#!/bin/bash
#******************************************************************************
# scripts/omx-track-latest.sh, the device follows the latest: zynthian-ui and
# zynthian-sys fast-forwarded to the newest signed omx-track/<YYYYMMDDXX> tag
# on the FreeMixer fork, the omx packages upgraded from the channel. zynthian
# is restarted only when something changed. One journal line per step. Run
# daily by omx-track-latest.timer (enabled by update_zynthian_sys.sh).
#
# zynthian-sys moves together with zynthian-webconf and zynthian-packages, all
# or none: the sys by its signed tag, the other two to the tip of the branch on
# the remote their checkout already has. When all three are in place the
# installed-packages list is created once, if missing, the way
# update_zynthian_data.sh does it.
#
# The branch tip of zynthian-ui and zynthian-sys is never taken. A tag is taken only when its signature is
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
CREATE_PACKAGES=${CREATE_PACKAGES:-$ZYNTHIAN_DIR/zynthian-sys/sbin/create_installed_packages.sh}
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

# Plan one checkout's move; nothing is changed but refs. <repo> <tag|tip>
#   tag: the newest signed track tag (zynthian-ui, zynthian-sys)
#   tip: the tip of $BRANCH on the remote the checkout already has, "fork"
#        when it has one, else "origin" (zynthian-webconf, zynthian-packages,
#        which have no fork and no tags of their own)
# Sets PLAN_COMMIT, PLAN_LABEL, PLAN_BEFORE. Returns 0 when it can be applied
# (PLAN_COMMIT may equal HEAD), 1 when it is blocked with a journal line saying
# why (PLAN_QUIET=1: not a failure, there is simply nothing to take).
plan_repo() {
	local repo=$1 mode=$2 name remote newest ref
	name=$(basename "$repo")
	PLAN_QUIET=0
	PLAN_FORGED=0
	PLAN_COMMIT=""
	PLAN_BEFORE=$("$GIT" -C "$repo" rev-parse HEAD)
	if [ "$mode" = tip ]; then
		remote=origin
		"$GIT" -C "$repo" remote get-url fork >/dev/null 2>&1 && remote=fork
		if ! "$GIT" -C "$repo" fetch -q "$remote" "$BRANCH"; then
			say "$name: fetch of $BRANCH from $remote failed"
			return 1
		fi
		PLAN_COMMIT=$("$GIT" -C "$repo" rev-parse "$remote/$BRANCH^{commit}") || return 1
		PLAN_LABEL="$BRANCH tip"
	else
		if ! remote=$(fork_remote "$repo"); then
			say "$name: no remote points at the fork, skipped"
			return 1
		fi
		if [ -z "$keyring" ] || [ -z "$pinned" ]; then
			say "$name: $nokey, staying at ${PLAN_BEFORE:0:9}"
			return 1
		fi
		# the fork's track tags, in a namespace of their own so no local tag is overwritten
		if ! "$GIT" -C "$repo" fetch -q --no-tags "$remote" "+refs/tags/$TAG_PREFIX*:refs/omx-track/$remote/*"; then
			say "$name: fetch from $remote failed"
			return 1
		fi
		# the newest tag that verifies; each one refused on the way is a journal line,
		# so a forged tag can neither be taken nor hide a good one behind it
		newest=""
		while IFS= read -r ref; do
			[ -n "$ref" ] || continue
			if PLAN_COMMIT=$(verified_commit "$repo" "$name" "$ref"); then
				newest=$ref
				break
			fi
			PLAN_FORGED=1
		done < <("$GIT" -C "$repo" for-each-ref --format='%(refname)' "refs/omx-track/$remote/" | sort -rV)
		if [ -z "$newest" ]; then
			say "$name: no signed $TAG_PREFIX tag to take, staying at ${PLAN_BEFORE:0:9}"
			PLAN_COMMIT=""
			PLAN_QUIET=1
			return 1
		fi
		PLAN_LABEL="signed ${newest##*/}"
	fi
	if [ -n "$("$GIT" -C "$repo" status --porcelain --untracked-files=no)" ]; then
		say "$name: working tree has local changes, left alone"
		return 1
	fi
	if ! "$GIT" -C "$repo" show-ref -q --verify "refs/heads/$BRANCH"; then
		"$GIT" -C "$repo" branch -q "$BRANCH" HEAD || return 1
	fi
	if "$GIT" -C "$repo" merge-base --is-ancestor "$PLAN_COMMIT" "$BRANCH"; then
		PLAN_COMMIT=$("$GIT" -C "$repo" rev-parse "$BRANCH")
		return 0
	fi
	if ! "$GIT" -C "$repo" merge-base --is-ancestor "$BRANCH" "$PLAN_COMMIT"; then
		say "$name: $BRANCH has local commits the $PLAN_LABEL lacks, left alone"
		return 1
	fi
	return 0
}

# Apply a plan: fast-forward to PLAN_COMMIT, MOVED=1 when the tip changed
apply_repo() {
	local repo=$1 name after
	name=$(basename "$repo")
	MOVED=0
	"$GIT" -C "$repo" checkout -q "$BRANCH" && "$GIT" -C "$repo" merge -q --ff-only "$PLAN_COMMIT" || {
		say "$name: fast-forward failed"
		return 1
	}
	after=$("$GIT" -C "$repo" rev-parse HEAD)
	if [ "$PLAN_BEFORE" = "$after" ]; then
		say "$name: already at ${after:0:9} ($PLAN_LABEL)"
	else
		say "$name: ${PLAN_BEFORE:0:9} -> ${after:0:9} ($PLAN_LABEL)"
		MOVED=1
		changed=1
	fi
}

track_repo() {
	local repo=$1
	if plan_repo "$repo" tag; then
		[ "$PLAN_FORGED" = 1 ] && failed=1
		apply_repo "$repo" || failed=1
	else
		[ "$PLAN_QUIET" = 1 ] || failed=1
	fi
}

# zynthian-sys, zynthian-webconf and zynthian-packages are one set: upstream's
# package system needs all three at one level. Each is planned first; if any
# cannot move, none does and the journal says which and why. A fast-forward
# that fails after another moved puts the moved ones back.
track_sys_set() {
	local sys=$1 dir r i n
	local repos=() commits=() befores=() labels=()
	dir=$(dirname "$sys")
	for r in "$sys" "${WEBCONF_DIR:-$dir/zynthian-webconf}" "${PACKAGES_DIR:-$dir/zynthian-packages}"; do
		if plan_repo "$r" "$([ "$r" = "$sys" ] && echo tag || echo tip)"; then
			[ "$PLAN_FORGED" = 1 ] && failed=1
			repos+=("$r")
			commits+=("$PLAN_COMMIT")
			befores+=("$PLAN_BEFORE")
			labels+=("$PLAN_LABEL")
			continue
		fi
		[ "$PLAN_QUIET" = 1 ] || failed=1
		say "zynthian-sys set: $(basename "$r") cannot move, zynthian-sys, zynthian-webconf and zynthian-packages left where they were"
		return
	done
	for i in 0 1 2; do
		PLAN_COMMIT=${commits[$i]} PLAN_BEFORE=${befores[$i]} PLAN_LABEL=${labels[$i]}
		if ! apply_repo "${repos[$i]}"; then
			say "zynthian-sys set: $(basename "${repos[$i]}") did not move, putting the others back"
			for ((n = 0; n < i; n++)); do
				"$GIT" -C "${repos[$n]}" reset -q --hard "${befores[$n]}"
			done
			failed=1
			return
		fi
		[ "$i" = 1 ] && [ "$MOVED" = 1 ] && webconf_moved=1
	done
	create_installed_packages
}

# Exactly as update_zynthian_data.sh does: once, when the directory is missing
create_installed_packages() {
	local cfg=${ZYNTHIAN_CONFIG_DIR:-$ZYNTHIAN_DIR/config}
	[ -d "$cfg/packages" ] && return
	if ZYNTHIAN_CONFIG_DIR=$cfg ZYNTHIAN_DATA_DIR=${ZYNTHIAN_DATA_DIR:-$ZYNTHIAN_DIR/zynthian-data} "$CREATE_PACKAGES"; then
		say "packages: installed-packages list created in $cfg/packages"
		changed=1
	else
		say "packages: create_installed_packages.sh failed, will retry next run"
		rm -rf "$cfg/packages"
		failed=1
	fi
}

versions() {
	local p
	for p in $PACKAGES; do
		"$DPKG_QUERY" -W -f '${Package} ${Version}\n' "$p" 2>/dev/null
	done
}

webconf_moved=0
for repo in $REPOS; do
	case "$(basename "$repo")" in
	zynthian-sys) track_sys_set "$repo" ;;
	*) track_repo "$repo" ;;
	esac
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
	[ "$webconf_moved" = 1 ] && { "$SYSTEMCTL" restart zynthian-webconf || failed=1; }
	"$SYSTEMCTL" restart zynthian || failed=1
else
	say "nothing changed, zynthian left running"
fi
exit $failed
