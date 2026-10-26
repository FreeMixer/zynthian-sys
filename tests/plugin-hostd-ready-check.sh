#!/bin/bash
#******************************************************************************
# mod-host-backend.sh start waits for the line plugin-hostd declares in its
# protocol.json, and for nothing else. The daemon here is a stand-in that
# opens no port at all, so a wait on the ports could never pass.
#
#   tests/plugin-hostd-ready-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
BACKEND=${BACKEND:-$HERE/../sbin/mod-host-backend.sh}

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/config"
echo "# stand-in" >"$work/config/plugin-hostd.conf"

# A daemon that prints its line after $FAKE_DELAY seconds, or never
cat >"$work/bin/plugin-hostd" <<'STUB'
#!/bin/bash
sleep "${FAKE_DELAY:-0}"
[ -n "$FAKE_SILENT" ] || echo "${FAKE_LINE:-plugin-hostd ready!}"
sleep 30
STUB
chmod +x "$work/bin/plugin-hostd"
echo '{"readiness": {"daemon_line": "fake-hostd is up", "worker_marker": "ready!"}}' >"$work/protocol.json"

start() {
	PATH="$work/bin:$PATH" ZYNTHIAN_CONFIG_DIR="$work/config" ZYNTHIAN_MODHOST_BACKEND=plugin-hostd \
		PHD_STATE="$work/run" PHD_PROTOCOL="${PROTOCOL:-$work/protocol.json}" PORT=59555 FEEDBACK_PORT=59556 \
		READY_TIMEOUT=${READY_TIMEOUT:-3} "$BACKEND" start 2>&1
}
cleanup() { pkill -f "$work/bin/plugin-hostd" 2>/dev/null; sleep 0.2; }

echo "-- the declared line, printed late"
started=$SECONDS
out=$(FAKE_LINE="fake-hostd is up" FAKE_DELAY=1 start); rc=$?
echo "$out" | sed 's/^/   | /'
check "start exits 0 once the declared line is printed" test $rc = 0
check "and not before it: no port ever opened, the wait was the line" test $((SECONDS - started)) -ge 1
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

echo "$fails failed"
exit $((fails > 0))
