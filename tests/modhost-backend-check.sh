#!/bin/bash
#******************************************************************************
# Check the plugin-hostd backend of mod-host end to end.
#
# Needs root, JACK running (the dummy driver is fine), plugin-hostd,
# omx-clap-host and omx-plugins installed, and port 5555 free: stop mod-ui
# and mod-host first on a Zynthian.
#
# It starts the backend with sbin/mod-host-backend.sh, as mod-host.service
# does, then talks the mod-host protocol on 5555 the way MOD-UI does: add,
# param_set, param_get and remove for one CLAP and one LV2 plugin, checking
# every reply and the JACK clients. Then it stops the backend and checks that
# no process and no JACK client is left.
#
# Other plugins: CLAP_PLUGIN, CLAP_PARAM, LV2_URI, LV2_PARAM, VALUE.
#******************************************************************************

SYS_DIR=$(cd "$(dirname "$0")/.." && pwd)
CLAP_PLUGIN=${CLAP_PLUGIN:-/usr/lib/clap/omx-drive.clap#org.openmixer.drive}
CLAP_PARAM=${CLAP_PARAM:-0}
LV2_URI=${LV2_URI:-urn:openmixer:drive}
LV2_PARAM=${LV2_PARAM:-amount}
VALUE=${VALUE:-9}
PORT=5555

fails=0
checks=0
ok() { checks=$((checks + 1)); echo "ok   $*"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

listening() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
phd_procs() { pgrep -f "^(/usr/bin/)?plugin-hostd .*-p $PORT( |$)"; }
# Children of our daemon: workers (omx-clap-host or mod-host with -p) and plugin scans
worker_procs() {
	pgrep -f '^(/usr/bin/|/usr/local/bin/)?(omx-clap-host|mod-host) .*-p [0-9]+'
	pgrep -f '^(/usr/bin/)?plugin-hostd-probe '
}
effect_ports() { jack_lsp 2>/dev/null | grep -E "^effect_($1):"; }

for cmd in plugin-hostd omx-clap-host jack_lsp python3 ss; do
	command -v "$cmd" >/dev/null || { echo "missing: $cmd"; exit 2; }
done
[ "$(id -u)" = 0 ] || { echo "run it as root"; exit 2; }
jack_lsp >/dev/null 2>&1 || { echo "JACK is not running"; exit 2; }
listening "$PORT" && { echo "port $PORT is in use: stop mod-ui and mod-host first"; exit 2; }

echo "plugin-hostd $(plugin-hostd -V | sed 's/.*: //'), omx-clap-host $(dpkg-query -W -f='${Version}' omx-clap-host 2>/dev/null)"
check "no plugin-hostd before start" test -z "$(phd_procs)"
check "no effect_1 or effect_2 JACK client before start" test -z "$(effect_ports '1|2')"

# A config dir of our own, so the backend installs the default config the way it does on first use
conf_dir=$(mktemp -d)
trap 'rm -rf "$conf_dir"' EXIT

backend() {
	ZYNTHIAN_MODHOST_BACKEND=plugin-hostd ZYNTHIAN_CONFIG_DIR="$conf_dir" ZYNTHIAN_SYS_DIR="$SYS_DIR" \
		"$SYS_DIR/sbin/mod-host-backend.sh" "$1"
}

echo "-- start"
backend start
check "backend start exits 0" test $? = 0
check "config installed from config/plugin-hostd.conf" cmp -s "$conf_dir/plugin-hostd.conf" "$SYS_DIR/config/plugin-hostd.conf"
check "plugin-hostd listens on 5555 and 5556" eval 'listening 5555 && listening 5556'

echo "-- protocol"
# The client keeps both sockets open, as MOD-UI does. Each line it prints is
# "ok|FAIL <command> -> <reply>"; JACK checks run between steps.
python3 -I - "$CLAP_PLUGIN" "$CLAP_PARAM" "$LV2_URI" "$LV2_PARAM" "$VALUE" <<'EOF' > "$conf_dir/protocol.out"
import socket, subprocess, sys

clap, clap_param, lv2, lv2_param, value = sys.argv[1:6]
cmd = socket.create_connection(("127.0.0.1", 5555), timeout=20)
fb = socket.create_connection(("127.0.0.1", 5556), timeout=20)

def send(line):
    cmd.sendall(line.encode() + b"\0")
    buf = b""
    while not buf.endswith(b"\0"):
        chunk = cmd.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf.rstrip(b"\0").decode(errors="replace")

def expect(line, test):
    try:
        reply = send(line)
    except OSError as e:
        reply = "no reply (%s)" % e
    print("%s %s -> %s" % ("ok  " if test(reply) else "FAIL", line, reply), flush=True)
    return reply

def is_value(want):
    def test(reply):
        w = reply.split()
        try:
            return len(w) == 3 and w[:2] == ["resp", "0"] and abs(float(w[2]) - float(want)) < 1e-3
        except ValueError:
            return False
    return test

def jack_clients(want_present, *instances):
    ports = subprocess.run(["jack_lsp"], capture_output=True, text=True).stdout.split("\n")
    for n in instances:
        present = any(p.startswith("effect_%d:" % n) for p in ports)
        print("%s JACK client effect_%d %s" % ("ok  " if present == want_present else "FAIL", n,
              "present" if present else "absent"), flush=True)

expect("add clap:%s 1" % clap, lambda r: r == "resp 1")
expect("param_set 1 %s %s" % (clap_param, value), lambda r: r == "resp 0")
expect("param_get 1 %s" % clap_param, is_value(value))
expect("add %s 2" % lv2, lambda r: r == "resp 2")
expect("param_set 2 %s %s" % (lv2_param, value), lambda r: r == "resp 0")
expect("param_get 2 %s" % lv2_param, is_value(value))
jack_clients(True, 1, 2)
expect("worker_list", lambda r: r.startswith("resp 2 "))
expect("remove 1", lambda r: r == "resp 0")
expect("remove 2", lambda r: r == "resp 0")
expect("worker_list", lambda r: r == "resp 0")
jack_clients(False, 1, 2)
EOF
check "protocol client ran" test $? = 0
while read -r status rest; do
	if [ "$status" = ok ]; then ok "$rest"; else bad "$rest"; fi
done < "$conf_dir/protocol.out"

echo "-- stop"
backend stop
check "backend stop exits 0" test $? = 0
sleep 0.5
check "no plugin-hostd left" test -z "$(phd_procs)"
check "no omx-clap-host or mod-host worker left" test -z "$(worker_procs)"
check "no effect_ JACK client left" test -z "$(effect_ports '[0-9]+')"
check "ports 5555 and 5556 closed" eval '! listening 5555 && ! listening 5556'

# Whatever a failed stop left must not stay on the machine
leftover="$(phd_procs) $(worker_procs)"
if [ -n "${leftover// /}" ]; then
	echo "killing what was left: $leftover"
	# shellcheck disable=SC2086
	kill -KILL $leftover 2>/dev/null
fi

echo "-- $((checks - fails))/$checks checks passed"
[ "$fails" = 0 ]
