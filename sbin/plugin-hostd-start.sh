#!/bin/bash
#******************************************************************************
# Start a plugin-hostd on a port and return once it is ready.
#
#   plugin-hostd-start.sh <port> [<feedback port>]
#
# The one place a plugin-hostd is started on this image: mod-host-backend.sh
# runs it for MOD-UI's daemon on 5555, and the UI's plugin-hostd engine runs it
# for its own on ZYNTHIAN_PLUGIN_HOSTD_PORT. Ready is the line the daemon
# declares in its protocol.json (readiness.daemon_line), printed once both its
# ports accept, and nothing else.
#
# A plugin-hostd already running on the port is left as it is, and that is
# success. Otherwise the daemon is started in the background with
# $PHD_CONF (installed from config/plugin-hostd.conf on first use), its output
# in $PHD_STATE/plugin-hostd-<port>.log, and the script prints its PID on
# stdout once the declared line is in that log. Without a feedback port the
# daemon has none (-n). Exit 1, with the reason on stderr, when the port is
# held by another program, the protocol file declares no line, or the daemon
# exits or stays silent for READY_TIMEOUT seconds (it is then stopped).
#******************************************************************************

ZYNTHIAN_CONFIG_DIR=${ZYNTHIAN_CONFIG_DIR:-/zynthian/config}
ZYNTHIAN_SYS_DIR=${ZYNTHIAN_SYS_DIR:-/zynthian/zynthian-sys}

PORT=$1
FEEDBACK_PORT=$2
PHD_CONF=${PHD_CONF:-$ZYNTHIAN_CONFIG_DIR/plugin-hostd.conf}
PHD_CONF_DEFAULT="$ZYNTHIAN_SYS_DIR/config/plugin-hostd.conf"
PHD_STATE=${PHD_STATE:-/run/plugin-hostd}
PHD_PROTOCOL=${PHD_PROTOCOL:-/usr/share/plugin-hostd/protocol.json}
READY_TIMEOUT=${READY_TIMEOUT:-10}

case "$PORT" in
	'' | *[!0-9]*)
		echo "Usage: $0 <port> [<feedback port>]" >&2
		exit 2
		;;
esac

# PIDs of plugin-hostd daemons on the command port
phd_pids() {
	pgrep -f "^(/usr/bin/)?plugin-hostd .*-p $PORT( |$)"
}

listening() {
	ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
}

# The line plugin-hostd declares for ready, from the protocol file its package installs
declared_ready_line() {
	python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["readiness"]["daemon_line"])' \
		"$PHD_PROTOCOL" 2>/dev/null || {
		echo "plugin-hostd declares no readiness line: $PHD_PROTOCOL is not readable" >&2
		return 1
	}
}

if [ -n "$(phd_pids)" ]; then
	echo "plugin-hostd is already running on port $PORT" >&2
	exit 0
fi
if listening "$PORT"; then
	echo "Port $PORT is held by another program, not starting plugin-hostd" >&2
	exit 1
fi
if [ ! -f "$PHD_CONF" ]; then
	echo "Installing $PHD_CONF from $PHD_CONF_DEFAULT" >&2
	cp "$PHD_CONF_DEFAULT" "$PHD_CONF" || exit 1
fi
ready_line=$(declared_ready_line) || exit 1

mkdir -p "$PHD_STATE"
log="$PHD_STATE/plugin-hostd-$PORT.log"
echo "Starting plugin-hostd on port $PORT${FEEDBACK_PORT:+ and $FEEDBACK_PORT} with $PHD_CONF" >&2
plugin-hostd -n -p "$PORT" ${FEEDBACK_PORT:+-f "$FEEDBACK_PORT"} -c "$PHD_CONF" </dev/null >"$log" 2>&1 &
pid=$!
for ((i = 0; i < READY_TIMEOUT * 10; i++)); do
	if grep -qxF "$ready_line" "$log"; then
		echo "$pid"
		exit 0
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		wait "$pid"
		echo "plugin-hostd exited with code $? before it was ready, see $log" >&2
		exit 1
	fi
	sleep 0.1
done
echo "plugin-hostd did not print '$ready_line' in $READY_TIMEOUT s, see $log" >&2
kill -TERM "$pid" 2>/dev/null
exit 1
