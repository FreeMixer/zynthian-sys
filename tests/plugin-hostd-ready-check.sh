#!/bin/bash
#******************************************************************************
# sbin/plugin-hostd-start.sh, the one place a plugin-hostd is started, waits
# for the line plugin-hostd declares in its protocol.json and for nothing
# else. The daemon here is a
# stand-in that opens no port at all, so a wait on the ports could never pass.
#
#   tests/plugin-hostd-ready-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
SBIN=$HERE/../sbin
START=${START:-$SBIN/plugin-hostd-start.sh}

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

work=$(mktemp -d)
mkdir -p "$work/bin" "$work/config"
echo "# stand-in" >"$work/config/plugin-hostd.conf"

# A daemon that prints its line after $FAKE_DELAY seconds, or never, then
# stays as a process named the way plugin-hostd is, with its arguments
cat >"$work/bin/plugin-hostd" <<'STUB'
#!/bin/bash
echo "$*" >>"$FAKE_ARGS"
sleep "${FAKE_DELAY:-0}"
[ -n "$FAKE_SILENT" ] || echo "${FAKE_LINE:-plugin-hostd ready!}"
exec -a plugin-hostd python3 -c 'import time; time.sleep(30)' "$@"
STUB
chmod +x "$work/bin/plugin-hostd"
echo '{"readiness": {"daemon_line": "fake-hostd is up", "worker_marker": "ready!"}}' >"$work/protocol.json"

env_run() {
	PATH="$work/bin:$PATH" ZYNTHIAN_CONFIG_DIR="$work/config" \
		PHD_STATE="$work/run" PHD_PROTOCOL="${PROTOCOL:-$work/protocol.json}" FAKE_ARGS="$work/args" \
		READY_TIMEOUT=${READY_TIMEOUT:-3} "$@"
}
start() { env_run "$START" 59555 59556 2>&1; }
cleanup() {
	pkill -f '^plugin-hostd .*-p 5955[57]( |$)' 2>/dev/null
	pkill -f "$work/bin/plugin-hostd" 2>/dev/null
	sleep 0.2
	rm -f "$work/args"
}
trap 'cleanup; rm -rf "$work"' EXIT

echo "-- the declared line, printed late"
started=$SECONDS
out=$(FAKE_LINE="fake-hostd is up" FAKE_DELAY=1 start); rc=$?
echo "$out" | sed 's/^/   | /'
check "start exits 0 once the declared line is printed" test $rc = 0
check "and not before it: no port ever opened, the wait was the line" test $((SECONDS - started)) -ge 1
check "the daemon got both ports and the config" \
	grep -qxF -- "-n -p 59555 -f 59556 -c $work/config/plugin-hostd.conf" "$work/args"
cleanup

echo "-- the line of another daemon is not ready"
out=$(FAKE_LINE="plugin-hostd ready!" READY_TIMEOUT=2 start); rc=$?
check "a different line is no readiness" test $rc = 1
check "and the failure names the line it waited for" grep -q "did not print 'fake-hostd is up'" <<<"$out"
cleanup

echo "-- a daemon that stays silent"
out=$(FAKE_SILENT=1 READY_TIMEOUT=1 start); rc=$?
check "start fails after READY_TIMEOUT" test $rc = 1
cleanup

echo "-- no protocol file"
out=$(PROTOCOL="$work/absent.json" FAKE_LINE="fake-hostd is up" start); rc=$?
check "no declared line, no start" test $rc = 1
check "and it says why" grep -q "declares no readiness line" <<<"$out"
cleanup

echo "-- the protocol file where libplugin-hostd-protocol0 installs it"
mkdir -p "$work/new"
echo '{"readiness": {"daemon_line": "new-home is up"}}' >"$work/new/plugin-hostd.json"
places="$work/new/plugin-hostd.json $work/protocol.json"
out=$(PHD_PROTOCOL= PHD_PROTOCOL_PLACES="$places" FAKE_LINE="new-home is up" READY_TIMEOUT=2 \
	env_run env PHD_PROTOCOL= PHD_PROTOCOL_PLACES="$places" "$START" 59555 59556 2>&1); rc=$?
check "plugin-hostd.json in the new home is read first" test $rc = 0
cleanup
rm "$work/new/plugin-hostd.json"
out=$(FAKE_LINE="fake-hostd is up" READY_TIMEOUT=2 \
	env_run env PHD_PROTOCOL= PHD_PROTOCOL_PLACES="$places" "$START" 59555 59556 2>&1); rc=$?
check "and protocol.json of a plugin-hostd before 0.16.0 when the new one is not there" test $rc = 0
cleanup

echo "-- plugin-hostd-start.sh, as the UI engine runs it"
pid=$(FAKE_LINE="fake-hostd is up" env_run "$START" 59557 2>/dev/null); rc=$?
check "it exits 0 once the declared line is printed" test $rc = 0
alive() { [[ $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }
check "and prints the PID of the daemon it started" alive "$pid"
check "without a feedback port the daemon has none" \
	grep -qxF -- "-n -p 59557 -c $work/config/plugin-hostd.conf" "$work/args"
check "its output is in a log of its own port" grep -qxF "fake-hostd is up" "$work/run/plugin-hostd-59557.log"
out=$(FAKE_LINE="fake-hostd is up" env_run "$START" 59557 2>&1 >"$work/again"); rc=$?
check "a daemon already on the port is success" test $rc = 0
check "and no second one is started" test "$(wc -l <"$work/args")" = 1
check "nor a PID printed for it: it is not the caller's" test ! -s "$work/again"
check "and it says so" grep -q "already running on port 59557" <<<"$out"
cleanup

echo "$fails failed"
exit $((fails > 0))
