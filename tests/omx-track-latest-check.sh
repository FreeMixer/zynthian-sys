#!/bin/bash
#******************************************************************************
# scripts/omx-track-latest.sh follows the newest signed omx-track tag of the
# fork, never the branch tip, and restarts only on a change; a commit pushed
# without a tag, a tag signed by another key or naming another repository, a
# lightweight tag and a device with no pinned key all leave it where it is;
# its units parse; update_zynthian_sys.sh installs and enables them.
#
#   tests/omx-track-latest-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
SCRIPT=$ROOT/scripts/omx-track-latest.sh

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

check "the script parses" bash -n "$SCRIPT"
check "the script is executable" test -x "$SCRIPT"

if command -v systemd-analyze >/dev/null; then
	w=$(mktemp -d)
	sed -e "s|#ZYNTHIAN_DIR#|/zynthian|; s|#ZYNTHIAN_SYS_DIR#|/bin|" \
		"$ROOT/etc/systemd/omx-track-latest.service" >"$w/omx-track-latest.service"
	cp "$ROOT/etc/systemd/omx-track-latest.timer" "$w/"
	out=$(systemd-analyze verify "$w/omx-track-latest.service" "$w/omx-track-latest.timer" 2>&1)
	if echo "$out" | grep -qE "omx-track-latest\.(service|timer).*(Unknown|Failed|error|not valid)"; then
		bad "systemd-analyze verify: $out"
	else
		ok "the unit files verify"
	fi
	rm -rf "$w"
else
	echo "skip systemd-analyze verify: not installed"
fi
check "the timer fires at 04:30" grep -q '^OnCalendar=\*-\*-\* 04:30:00' "$ROOT/etc/systemd/omx-track-latest.timer"
check "the update script enables the timer" grep -q 'enable --now omx-track-latest.timer' "$ROOT/scripts/update_zynthian_sys.sh"
check "the update script fills the service placeholders" grep -q 's/#ZYNTHIAN_SYS_DIR#/$ZYNTHIAN_SYS_DIR_ESC/g" /etc/systemd/system/omx-track-latest.service' "$ROOT/scripts/update_zynthian_sys.sh"

# Behaviour against a local "fork", with throwaway keys: "release" is pinned,
# "intruder" is not
w=$(mktemp -d)
export GNUPGHOME=$w/gnupg GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Release <release@example.org>' ed25519 sign 1y
gpg --batch --quiet --passphrase '' --quick-gen-key 'Intruder <intruder@example.org>' ed25519 sign 1y
fpr() { gpg --batch --with-colons --fingerprint "$1" | awk -F: '/^fpr:/ {print $10; exit}'; }
gpg --batch --armor --export "$(fpr release@example.org)" >"$w/pinned.asc"
TAG=$ROOT/scripts/omx-track-tag.sh
git -c init.defaultBranch=vangelis init -q --bare "$w/fork.git"
git -c init.defaultBranch=vangelis init -q "$w/src"
g() { git -C "$w/src" -c user.name=t -c user.email=t@t "$@"; }
echo 1 >"$w/src/f"; g add f; g commit -qm one; g remote add o "$w/fork.git"; g push -q o vangelis
mkdir -p "$w/dev" "$w/bin"
git clone -q "$w/fork.git" "$w/dev/zui"
git -C "$w/dev/zui" remote rename origin fork
# the stand-in URL must name the fork
pat=$w/fork.git
cat >"$w/bin/apt" <<'S'
#!/bin/bash
echo "$@" >>"$APT_LOG"
S
cat >"$w/bin/dq" <<'S'
#!/bin/bash
echo "omx-panel $(cat "$PKGV")"
S
cat >"$w/bin/sc" <<'S'
#!/bin/bash
echo "$@" >>"$SC_LOG"
S
chmod +x "$w/bin"/*
echo 1.0 >"$w/pkgv"
keys=$w/pinned.asc
run() {
	: >"$w/sc.log"
	FORK_URL_PATTERN=$pat REPOS="$w/dev/zui" PACKAGES=omx-panel HOLD_FILE="$w/hold" TRACK_KEYS=$keys \
		APT_GET="$w/bin/apt" DPKG_QUERY="$w/bin/dq" SYSTEMCTL="$w/bin/sc" \
		APT_LOG="$w/apt.log" SC_LOG="$w/sc.log" PKGV="$w/pkgv" "$SCRIPT" 2>&1
}
head_of() { git -C "$w/dev/zui" rev-parse HEAD; }
signed_tag() { "$TAG" "$w/src" --name "${2:-zui}" --key "$(fpr "$1")" --push o >/dev/null; }
start=$(head_of)

out=$(run)
check "no tag on the fork: nothing moves, no restart" test "$(head_of)" = "$start" -a ! -s "$w/sc.log"
check "no tag on the fork: the journal says so" grep -q 'no signed omx-track/ tag to take' <<<"$out"

echo 2 >"$w/src/f"; g commit -qam two; g push -q o vangelis
out=$(run)
check "a commit pushed to the branch without a signed tag is not taken" test "$(head_of)" = "$start"

signed_tag release@example.org
out=$(run); rc=$?
check "a tag signed by the pinned key is taken" test "$(head_of)" = "$(g rev-parse HEAD)"
check "a change restarts zynthian once" test "$(cat "$w/sc.log")" = "restart zynthian"
check "a step is one journal line" test "$(echo "$out" | grep -c 'zui: ')" = 1
check "the journal names the tag" grep -q 'zui: .* -> .* (signed 20' <<<"$out"
check "a clean run exits 0" test "$rc" = 0
two=$(head_of)

echo 3 >"$w/src/f"; g commit -qam three; g push -q o vangelis
g tag -s -u "$(fpr intruder@example.org)" -m 'repository: zui' omx-track/2099123199; g push -q o refs/tags/omx-track/2099123199
out=$(run); rc=$?
check "a tag signed by another key is not taken" test "$(head_of)" = "$two"
check "a tag signed by another key is reported and fails the run" test "$rc" = 1
check "the journal says the signature is not pinned" grep -q 'omx-track/2099123199 has no good signature by a pinned key' <<<"$out"
check "a forged newer tag does not hide the good one, and nothing restarts" test ! -s "$w/sc.log"

signed_tag release@example.org other-repo
out=$(run)
check "a tag naming another repository is not taken" test "$(head_of)" = "$two"
check "the journal says it names another repository" grep -q 'does not name zui and itself' <<<"$out"

g tag omx-track/2099123198; g push -q o refs/tags/omx-track/2099123198
out=$(run)
check "a lightweight tag is not taken" test "$(head_of)" = "$two"

signed_tag release@example.org
keys=$w/absent.asc
out=$(run); rc=$?
check "no pinned key: the device stays where it is" test "$(head_of)" = "$two" -a "$rc" = 1
check "no pinned key: the journal says so" grep -q 'no pinned signing key at' <<<"$out"
keys=$w/pinned.asc
out=$(run)
check "with the key back, the newest good tag is taken past the forged ones" test "$(head_of)" = "$(g rev-parse HEAD)"

: >"$w/sc.log"
touch "$w/hold"; echo 4 >"$w/src/f"; g commit -qam four; g push -q o vangelis; signed_tag release@example.org
out=$(run)
check "the hold file touches nothing" test "$(head_of)" != "$(g rev-parse HEAD)"
rm "$w/hold"
echo local >"$w/dev/zui/l"; git -C "$w/dev/zui" add l; git -C "$w/dev/zui" -c user.name=t -c user.email=t@t commit -qm local
out=$(run); rc=$?
check "local commits are left alone and reported" test "$rc" = 1 -a "$(git -C "$w/dev/zui" log -1 --format=%s)" = local
rm -rf "$w"
unset GNUPGHOME GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL

echo
[ "$fails" = 0 ] && echo "all ok" || echo "$fails failed"
exit $((fails > 0))
