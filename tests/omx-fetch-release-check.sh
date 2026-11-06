#!/bin/bash
#******************************************************************************
# scripts/omx-fetch-release.sh hands over the openmixer-release .deb only when
# it is the newest one listed by a Packages file that an InRelease signed by
# the pinned archive key names. A channel signed by another key, a Packages
# file changed after signing, a swapped .deb, a path out of the suite and a
# missing pinned key each write nothing and exit 1. A throwaway channel on
# disk, served through file:// URLs. Needs gpg, gpgv, curl and dpkg.
#
#   tests/omx-fetch-release-check.sh
#******************************************************************************

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../scripts/omx-fetch-release.sh

fails=0
ok() { echo "ok   $*"; }
bad() { fails=$((fails + 1)); echo "FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

check "the script parses" bash -n "$SCRIPT"
check "the script is executable" test -x "$SCRIPT"
check "the archive key is pinned in the tree" test -s "$HERE/../keys/openmixer-archive-keyring.asc"
check "the install recipe fetches through it" grep -q 'scripts/omx-fetch-release.sh' "$HERE/../scripts/recipes/install_openmixer.sh"
check "the image setup fetches through it" grep -q 'zynthian-sys/scripts/omx-fetch-release.sh' "$HERE/../scripts/setup_system_raspioslite_64bit_trixie.sh"
check "no install path downloads the package unchecked" \
	bash -c "! grep -n 'openmixer-release.deb' '$HERE/../scripts/recipes/install_openmixer.sh' '$HERE/../scripts/setup_system_raspioslite_64bit_trixie.sh' | grep -q 'wget\|curl'"

w=$(mktemp -d)
export GNUPGHOME=$w/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Archive <archive@example.org>' ed25519 sign 1y
gpg --batch --quiet --passphrase '' --quick-gen-key 'Intruder <intruder@example.org>' ed25519 sign 1y
gpg --batch --armor --export archive@example.org >"$w/pinned.asc"
suite=$w/channel/debian/trixie
mkdir -p "$suite/all"
printf 'old release\n' >"$suite/all/openmixer-release_1-2_all.deb"
printf 'new release\n' >"$suite/all/openmixer-release_1-3_all.deb"
printf 'other\n' >"$suite/all/other_1_all.deb"
stanza() { printf 'Package: %s\nVersion: %s\nArchitecture: all\nFilename: %s\nSHA256: %s\n\n' "$1" "$2" "$3" "$(sha256sum <"$suite/${3#./}" | cut -d' ' -f1)"; }
index() {
	{ stanza openmixer-release 1-2 ./all/openmixer-release_1-2_all.deb
	  stanza openmixer-release 1-3 ./all/openmixer-release_1-3_all.deb
	  stanza other 1 ./all/other_1_all.deb; } >"$suite/Packages"
	printf 'Origin: t\nSuite: trixie\nSHA256:\n %s %s Packages\n' "$(sha256sum <"$suite/Packages" | cut -d' ' -f1)" "$(stat -c %s "$suite/Packages")" >"$suite/Release"
	gpg --batch --yes --local-user "${1:-archive@example.org}" --clearsign --output "$suite/InRelease" "$suite/Release"
}
fetch() { rm -f "$w/out.deb"; BASE_URL="file://$w/channel" SUITE=trixie ARCHIVE_KEYS=${keys:-$w/pinned.asc} "$SCRIPT" "$w/out.deb" 2>&1; }

index
out=$(fetch); rc=$?
check "a signed channel: the newest openmixer-release is written" test "$rc" = 0 -a "$(cat "$w/out.deb" 2>/dev/null)" = "new release"
check "a signed channel: the journal names the version" grep -q 'openmixer-release 1-3' <<<"$out"

index intruder@example.org
out=$(fetch); rc=$?
check "a channel signed by another key writes nothing" test "$rc" = 1 -a ! -e "$w/out.deb"
check "a channel signed by another key says so" grep -q 'no good signature by the pinned archive key' <<<"$out"

index
printf 'Package: extra\n\n' >>"$suite/Packages"
out=$(fetch); rc=$?
check "a Packages file changed after signing writes nothing" test "$rc" = 1 -a ! -e "$w/out.deb"

index
printf 'swapped\n' >"$suite/all/openmixer-release_1-3_all.deb"
out=$(fetch); rc=$?
check "a swapped .deb writes nothing" test "$rc" = 1 -a ! -e "$w/out.deb"
check "a swapped .deb says so" grep -q 'is not the openmixer-release 1-3 the signed index lists' <<<"$out"
printf 'new release\n' >"$suite/all/openmixer-release_1-3_all.deb"

mkdir -p "$w/channel/debian/evil"; printf 'evil\n' >"$w/channel/debian/evil/x.deb"
{ printf 'Package: openmixer-release\nVersion: 9\nArchitecture: all\nFilename: ../evil/x.deb\nSHA256: %s\n\n' "$(sha256sum <"$w/channel/debian/evil/x.deb" | cut -d' ' -f1)"; } >"$suite/Packages"
printf 'Origin: t\nSuite: trixie\nSHA256:\n %s %s Packages\n' "$(sha256sum <"$suite/Packages" | cut -d' ' -f1)" "$(stat -c %s "$suite/Packages")" >"$suite/Release"
gpg --batch --yes --local-user archive@example.org --clearsign --output "$suite/InRelease" "$suite/Release"
out=$(fetch); rc=$?
check "a path out of the suite writes nothing" test "$rc" = 1 -a ! -e "$w/out.deb"

index
keys=$w/absent.asc
out=$(fetch); rc=$?
check "no pinned archive key writes nothing" test "$rc" = 1 -a ! -e "$w/out.deb"
unset keys
rm -rf "$w"
unset GNUPGHOME

echo
[ "$fails" = 0 ] && echo "all ok" || echo "$fails failed"
exit $((fails > 0))
