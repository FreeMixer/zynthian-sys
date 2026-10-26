#!/bin/bash
#******************************************************************************
# omx-modgui-sync.sh asks omx-panel for the installed descriptors instead of
# globbing a contract major itself. Runs with stand-ins for omx-panel and for
# python3-lilv, so it needs neither; the real run is omx-modgui-sync-check.sh.
#
#   tests/omx-modgui-sync-installed-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
SYNC=${SYNC:-$HERE/../scripts/omx-modgui-sync.sh}
REAL_PYTHON=$(command -v python3)

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/contract/9/omx-plugins/plugins" "$work/modgui" "$work/state" "$work/desc"

# The descriptor omx-panel lists, under a contract major the script never names
cat >"$work/contract/9/omx-plugins/plugins/omx-delay.json" <<'JSON'
{"plugin": {"format": "lv2", "uri": "urn:test:delay"}, "controls": [{"id": "time"}]}
JSON

cat >"$work/bin/omx-panel" <<STUB
#!/bin/bash
if [ "\$1 \$2" = "descriptors --installed" ]; then
	[ -n "\$STUB_PANEL_FAIL" ] && exit 3
	echo "$work/contract/9/omx-plugins/plugins/omx-delay.json"
	exit 0
fi
echo "unexpected: \$*" >&2
exit 64
STUB

# python3 whose lilv knows one plugin
cat >"$work/bin/python3" <<STUB
#!/bin/bash
if [ "\$1 \$2" = "-I -" ]; then
	shift 2
	exec "$REAL_PYTHON" -I -c '
import sys, types
class U(str):
    pass
class P:
    def get_uri(self): return "urn:test:delay"
    def get_bundle_uri(self): return "file:///usr/lib/lv2/omx-delay.lv2/"
    def get_value(self, _): return []
class W:
    def load_all(self): pass
    def new_uri(self, u): return u
    def get_all_plugins(self): return [P()]
sys.modules["lilv"] = types.SimpleNamespace(World=W)
sys.argv = ["-"] + sys.argv[1:]
exec(compile(sys.stdin.read(), "plan", "exec"))
' "\$@"
fi
exec "$REAL_PYTHON" "\$@"
STUB
chmod +x "$work/bin/omx-panel" "$work/bin/python3"

run() {
	PATH="$work/bin:$PATH" LV2_PATH="$work/modgui" MODGUI_DIR="$work/modgui" STATE_DIR="$work/state" \
		DESCRIPTOR_DIRS="$work/desc" ZYNTHIAN_CONFIG_DIR="$work/config" "$SYNC" --dry-run --no-scan "$@" 2>&1
}

out=$(run)
echo "$out" | sed 's/^/   | /'
check "the installed descriptor is found whatever its contract major" \
	grep -q "would write .*omx-delay.*urn:test:delay from --installed omx-plugins/omx-delay" <<<"$out"
check "no major is named in the script" bash -c "! grep -n 'contract_dir\|\"3\"' '$SYNC'"

STUB_PANEL_FAIL=1 run >/dev/null; rc=$?
check "and exits 1, not a quiet empty list" test "$rc" = 1

echo "$fails failed"
exit $((fails > 0))
