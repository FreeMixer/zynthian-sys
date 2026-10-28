#!/bin/bash
#******************************************************************************
# scripts/omx-track-latest.sh, the device follows the latest: zynthian-ui and
# zynthian-sys fast-forwarded to the tip of vangelis on the FreeMixer fork, the
# omx packages upgraded from the channel. zynthian is restarted only when
# something changed. One journal line per step. Run daily by
# omx-track-latest.timer (enabled by update_zynthian_sys.sh).
#
# The UI keeps "a chain is playing" inside its own process and exposes it
# nowhere a unit can read, so this script cannot refuse on it. What it can
# honour is a hold file: while HOLD_FILE exists nothing is touched.
#******************************************************************************

BRANCH=${BRANCH:-vangelis}
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

track_repo() {
	local repo=$1 name remote before after
	name=$(basename "$repo")
	if ! remote=$(fork_remote "$repo"); then
		say "$name: no remote points at the fork, skipped"
		failed=1
		return
	fi
	if ! "$GIT" -C "$repo" fetch -q "$remote" "$BRANCH"; then
		say "$name: fetch from $remote failed"
		failed=1
		return
	fi
	if [ -n "$("$GIT" -C "$repo" status --porcelain --untracked-files=no)" ]; then
		say "$name: working tree has local changes, left alone"
		failed=1
		return
	fi
	if ! "$GIT" -C "$repo" show-ref -q --verify "refs/heads/$BRANCH"; then
		"$GIT" -C "$repo" branch -q "$BRANCH" "$remote/$BRANCH" || { failed=1; return; }
	fi
	if ! "$GIT" -C "$repo" merge-base --is-ancestor "$BRANCH" "$remote/$BRANCH"; then
		say "$name: $BRANCH has local commits the fork lacks, left alone"
		failed=1
		return
	fi
	before=$("$GIT" -C "$repo" rev-parse HEAD)
	"$GIT" -C "$repo" checkout -q "$BRANCH" && "$GIT" -C "$repo" merge -q --ff-only "$remote/$BRANCH" || {
		say "$name: fast-forward failed"
		failed=1
		return
	}
	after=$("$GIT" -C "$repo" rev-parse HEAD)
	if [ "$before" = "$after" ]; then
		say "$name: already at ${after:0:9}"
	else
		say "$name: ${before:0:9} -> ${after:0:9}"
		changed=1
	fi
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
