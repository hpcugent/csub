#!/bin/bash

here=$(pwd)

export BDISTRPMBASEDIR="$here/rpmbuild"
rm -Rf "$BDISTRPMBASEDIR"
mkdir -p "$BDISTRPMBASEDIR"/{BUILD,RPMS,SRPMS,SOURCES}

./buildrpmfromspec.sh

cd "$here"
rm -Rf dist
mkdir -p dist

find "$BDISTRPMBASEDIR" -regex '.*/RPMS/.*rpm' -print0 | grep -v debuginfo | xargs -0 -I '{}' cp '{}' dist

#rm -Rf "$BDISTRPMBASEDIR"
