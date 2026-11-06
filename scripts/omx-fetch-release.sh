#!/bin/bash
#******************************************************************************
# scripts/omx-fetch-release.sh, the first OpenMixer package of a new install,
# fetched so that it is the one the channel signed:
#
#   omx-fetch-release.sh <out.deb>
#
# The channel's InRelease for this Debian release must carry a good signature
# by a key in keys/openmixer-archive-keyring.asc of this checkout. The
# Packages file must be the one it names, and the openmixer-release .deb must
# be the newest the Packages lists, with the SHA256 it lists. Anything else
# writes nothing and exits 1, saying why. apt installs a local .deb without
# checking a signature, and its postinst runs as root; this check is what
# stands in for one on the first install, before openmixer-release has put
# the key where apt reads it.
#
# BASE_URL, SUITE, ARCHIVE_KEYS and FETCH (a command writing <url> to stdout)
# may be set for tests.
#******************************************************************************
set -euo pipefail

out=${1:?usage: omx-fetch-release.sh <out.deb>}
BASE_URL=${BASE_URL:-https://www.openmixer.org/deb}
SUITE=${SUITE:-$(. /etc/os-release && echo "${VERSION_CODENAME:-}")}
ARCHIVE_KEYS=${ARCHIVE_KEYS:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/keys/openmixer-archive-keyring.asc}
FETCH=${FETCH:-curl -fsSL --retry 3 --connect-timeout 20}

refuse() { echo "omx-fetch-release: $*, nothing installed" >&2; exit 1; }
command -v gpg >/dev/null && command -v gpgv >/dev/null || refuse "gpg and gpgv are needed to check the channel's signature (apt-get install gnupg)"
[ -n "$SUITE" ] || refuse "no Debian release name in /etc/os-release"
[ -s "$ARCHIVE_KEYS" ] || refuse "no pinned archive key at $ARCHIVE_KEYS"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
base=${BASE_URL%/}/debian/$SUITE

gpg --batch --yes --dearmor <"$ARCHIVE_KEYS" >"$work/keyring" 2>/dev/null || refuse "the pinned archive key does not read"
$FETCH "$base/InRelease" >"$work/InRelease" || refuse "could not fetch $base/InRelease"
$FETCH "$base/Packages" >"$work/Packages" || refuse "could not fetch $base/Packages"

# gpgv exits non-zero when one signature of a co-signed index is by a key it
# lacks: a VALIDSIG and no BADSIG is the verdict
status=$(gpgv --status-fd 1 --keyring "$work/keyring" --output "$work/Release" "$work/InRelease" 2>/dev/null || true)
printf '%s\n' "$status" | grep -q ' VALIDSIG ' && ! printf '%s\n' "$status" | grep -q ' BADSIG ' ||
	refuse "$base/InRelease has no good signature by the pinned archive key"

want=$(awk '/^SHA256:/ {s = 1; next} /^[^ ]/ {s = 0} s && $3 == "Packages" {print $1}' "$work/Release")
got=$(sha256sum <"$work/Packages" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] || refuse "$base/Packages is not the one the signed InRelease names"

# the newest openmixer-release the signed Packages lists: version, file, sha256
best=""
while IFS='|' read -r version file sum; do
	if [ -z "$best" ] || dpkg --compare-versions "$version" gt "${best%%|*}"; then best="$version|$file|$sum"; fi
done < <(awk '/^Package:/ {p = $2} /^Version:/ {v = $2} /^Filename:/ {f = $2} /^SHA256:/ {h = $2}
	/^$/ {if (p == "openmixer-release") print v "|" f "|" h; p = ""} END {if (p == "openmixer-release") print v "|" f "|" h}' "$work/Packages")
[ -n "$best" ] || refuse "the signed Packages lists no openmixer-release"
IFS='|' read -r version file sum <<<"$best"
case $file in ./*) file=${file#./} ;; esac
case $file in *..*|/*) refuse "the signed Packages names an odd path for openmixer-release: $file" ;; esac

$FETCH "$base/$file" >"$work/release.deb" || refuse "could not fetch $base/$file"
[ "$(sha256sum <"$work/release.deb" | cut -d' ' -f1)" = "$sum" ] || refuse "$base/$file is not the openmixer-release $version the signed index lists"
install -m 0644 "$work/release.deb" "$out"
echo "omx-fetch-release: openmixer-release $version, signed index of $SUITE, sha256 $sum"
