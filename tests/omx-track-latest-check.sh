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
# The sys set: zynthian-sys (signed tag), zynthian-webconf and zynthian-packages
# (tip of the branch on the remote they already have) move together or not at all
S=$w/set
mkdir -p "$S/z" "$S/cfg"
# The branch each repository really has upstream. Not invented: the check right
# below refuses these names when the real scripts say otherwise (a fixture that
# used vangelis for zynthian-packages hid a refusal on every device)
sbr() { case $1 in zynthian-packages) echo main ;; *) echo vangelis ;; esac; }
sd=$(cd "$(dirname "$0")/.." && pwd)/scripts
stable=$(sed -n 's/^export ZYNTHIAN_STABLE_BRANCH="\(.*\)"/\1/p' "$sd/zynthian_envars_extended.sh")
check "fixture branches: webconf is cloned on the stable branch, as the fixture has it" test "$(grep -c -E 'clone .*-b "\$\{ZYNTHIAN_WEBCONF_BRANCH\}"' "$sd/reset_zynthian_repos.sh")" = 1 -a "$stable" = "$(sbr zynthian-webconf)"
check "fixture branches: packages is cloned with no -b (upstream default, main), as the fixture has it" test "$(grep -E 'clone .*ZYNTHIAN_PACKAGES_REPO' "$sd/reset_zynthian_repos.sh" | grep -c -- ' -b ')" = 0 -a "$(sbr zynthian-packages)" = main
check "fixture branches: update_zynthian_data.sh pulls packages on the checkout's own branch" bash -c 'sed -n "/zynthian-packages\"/,/git pull/p" "$1" | grep -qx "git pull"' _ "$sd/update_zynthian_data.sh"
for n in zynthian-sys zynthian-webconf zynthian-packages; do
	git -c init.defaultBranch="$(sbr $n)" init -q --bare "$S/$n.git"
	git -c init.defaultBranch="$(sbr $n)" init -q "$S/src-$n"
	echo 1 >"$S/src-$n/f"
	git -C "$S/src-$n" -c user.name=t -c user.email=t@t add f
	git -C "$S/src-$n" -c user.name=t -c user.email=t@t commit -qm one
	git -C "$S/src-$n" remote add o "$S/$n.git"; git -C "$S/src-$n" push -q o "$(sbr $n)"
	git clone -q "$S/$n.git" "$S/z/$n"
done
# zynthian-sys has a fork remote; webconf and packages keep their origin, which does not name the fork
git -C "$S/z/zynthian-sys" remote rename origin fork
printf '#!/bin/bash\necho "$ZYNTHIAN_CONFIG_DIR" >>"$CREATE_LOG"; mkdir -p "$ZYNTHIAN_CONFIG_DIR/packages"\n' >"$S/create"
chmod +x "$S/create"
spush() { echo "$2" >"$S/src-$1/f"; git -C "$S/src-$1" -c user.name=t -c user.email=t@t commit -qam "$2"; git -C "$S/src-$1" push -q o "$(sbr $1)"; }
stip() { git -C "$S/z/$1" rev-parse HEAD; }
ssrc() { git -C "$S/src-$1" rev-parse HEAD; }
stag() { "$TAG" "$S/src-zynthian-sys" --name zynthian-sys --key "$(fpr release@example.org)" --push o >/dev/null; }
srun() {
	: >"$w/sc.log"
	FORK_URL_PATTERN=$S/zynthian-sys.git REPOS="$S/z/zynthian-sys" PACKAGES=omx-panel HOLD_FILE="$w/hold" TRACK_KEYS=$keys \
		APT_GET="$w/bin/apt" DPKG_QUERY="$w/bin/dq" SYSTEMCTL="$w/bin/sc" ZYNTHIAN_CONFIG_DIR="$S/cfg" \
		CREATE_PACKAGES="$S/create" CREATE_LOG="$S/create.log" \
		APT_LOG="$w/apt.log" SC_LOG="$w/sc.log" PKGV="$w/pkgv" "$SCRIPT" 2>&1
}
spush zynthian-sys two; spush zynthian-webconf two; spush zynthian-packages two; stag
out=$(srun); rc=$?
check "sys set: sys moves to the signed tag" test "$(stip zynthian-sys)" = "$(ssrc zynthian-sys)"
check "sys set: webconf follows" test "$(stip zynthian-webconf)" = "$(ssrc zynthian-webconf)"
check "sys set: packages follows" test "$(stip zynthian-packages)" = "$(ssrc zynthian-packages)"
check "sys set: the create step ran once" test "$(wc -l <"$S/create.log" 2>/dev/null)" = 1
check "sys set: webconf and zynthian restarted" test "$(cat "$w/sc.log")" = "$(printf 'restart zynthian-webconf\nrestart zynthian')"
check "sys set: a clean run exits 0" test "$rc" = 0
srun >/dev/null
check "sys set: the create step is not run again" test "$(wc -l <"$S/create.log")" = 1
# webconf cannot move: nothing moves, the journal says why
spush zynthian-sys three; spush zynthian-webconf three; spush zynthian-packages three; stag
echo dirty >>"$S/z/zynthian-webconf/f"
before=$(stip zynthian-sys)$(stip zynthian-webconf)$(stip zynthian-packages)
out=$(srun); rc=$?
check "sys set: one blocked, none moves" test "$(stip zynthian-sys)$(stip zynthian-webconf)$(stip zynthian-packages)" = "$before"
check "sys set: the journal says which and why" bash -c 'grep -q "zynthian-webconf: working tree has local changes" <<<"$1" && grep -q "zynthian-webconf cannot move.*left where they were" <<<"$1"' _ "$out"
check "sys set: a blocked run fails and restarts nothing" test "$rc" = 1 -a ! -s "$w/sc.log"
git -C "$S/z/zynthian-webconf" checkout -q f
# a device whose sys is already current but webconf is behind (today's state) catches up
spush zynthian-webconf four
git -C "$S/z/zynthian-sys" merge -q --ff-only "$(ssrc zynthian-sys)" 2>/dev/null
out=$(srun)
check "sys set: webconf catches up when sys is already current" test "$(stip zynthian-webconf)" = "$(ssrc zynthian-webconf)"
# the create step failing is retried, not remembered
rm -rf "$S/cfg/packages"; printf '#!/bin/bash\nmkdir -p "$ZYNTHIAN_CONFIG_DIR/packages"; exit 1\n' >"$S/create"
out=$(srun); rc=$?
check "sys set: a failed create step fails the run and leaves no half list" test "$rc" = 1 -a ! -d "$S/cfg/packages"
rm -rf "$w"
unset GNUPGHOME GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL

echo
[ "$fails" = 0 ] && echo "all ok" || echo "$fails failed"
exit $((fails > 0))
