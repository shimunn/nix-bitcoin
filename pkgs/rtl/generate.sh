#!/usr/bin/env nix-shell
#! nix-shell -i bash -p gnupg wget gnused
set -euo pipefail

version="0.13.0"
repo=https://github.com/Ride-The-Lightning/RTL

scriptDir=$(cd "${BASH_SOURCE[0]%/*}" && pwd)

updateSrc() {
    TMPDIR="$(mktemp -d /tmp/rtl.XXX)"
    trap "rm -rf $TMPDIR" EXIT

    # Fetch and verify source tarball
    export GNUPGHOME=$TMPDIR
    # Fetch saubyk's key
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-key 3E9BD4436C288039CA827A9200C9E2BC2E45666F
    file=v${version}.tar.gz
    wget -P $TMPDIR $repo/archive/refs/tags/$file
    wget -P $TMPDIR $repo/releases/download/v${version}/$file.asc
    gpg --verify $TMPDIR/$file.asc $TMPDIR/$file
    hash=$(nix hash file $TMPDIR/$file)

    sed -i "
      s|\bversion = .*;|version = \"$version\";|
      s|\bhash = .*;|hash = \"$hash\";|
    " default.nix
}

updateNodeModulesHash() {
    $scriptDir/../../helper/update-fixed-output-derivation.sh ./default.nix rtl.nodeModules nodeModules
}

if [[ $# == 0 ]]; then
    # Each of these can be run separately
    updateSrc
    updateNodeModulesHash
else
    eval "$@"
fi
