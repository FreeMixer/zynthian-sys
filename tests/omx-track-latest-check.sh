#!/bin/bash
#******************************************************************************
# scripts/omx-track-latest.sh follows the fork tip and restarts only on a
# change; its units parse; update_zynthian_sys.sh installs and enables them.
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

# Behaviour against a local "fork"
w=$(mktemp -d)
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
run() {
	: >"$w/sc.log"
	FORK_URL_PATTERN=$pat REPOS="$w/dev/zui" PACKAGES=omx-panel HOLD_FILE="$w/hold" \
		APT_GET="$w/bin/apt" DPKG_QUERY="$w/bin/dq" SYSTEMCTL="$w/bin/sc" \
		APT_LOG="$w/apt.log" SC_LOG="$w/sc.log" PKGV="$w/pkgv" "$SCRIPT" 2>&1
}
out=$(run)
check "no change: no restart" test ! -s "$w/sc.log"
echo 2 >"$w/src/f"; g commit -qam two; g push -q o vangelis
out=$(run); rc=$?
check "a new fork commit is fast-forwarded" test "$(git -C "$w/dev/zui" rev-parse HEAD)" = "$(g rev-parse HEAD)"
check "a change restarts zynthian once" test "$(cat "$w/sc.log")" = "restart zynthian"
check "a step is one journal line" test "$(echo "$out" | grep -c 'zui: ')" = 1
: >"$w/sc.log"
touch "$w/hold"; echo 3 >"$w/src/f"; g commit -qam three; g push -q o vangelis
out=$(run)
check "the hold file touches nothing" test "$(git -C "$w/dev/zui" rev-parse HEAD)" != "$(g rev-parse HEAD)"
rm "$w/hold"
echo local >"$w/dev/zui/l"; git -C "$w/dev/zui" add l; git -C "$w/dev/zui" -c user.name=t -c user.email=t@t commit -qm local
out=$(run); rc=$?
check "local commits are left alone and reported" test "$rc" = 1 -a "$(git -C "$w/dev/zui" log -1 --format=%s)" = local
rm -rf "$w"

echo
[ "$fails" = 0 ] && echo "all ok" || echo "$fails failed"
exit $((fails > 0))
