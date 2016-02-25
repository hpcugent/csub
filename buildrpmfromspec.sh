#!/bin/bash

if [[ -z "$1" || -d "$1" ]];then
    echo "You didn't specify anything to build";
    if [ -d "$1" ]
    then
        cd "$1"
    fi
    spec=$(ls ./*spec | head -1)
    if [ -z "$spec" ]
    then
        echo "No spec file found. Exiting."
        exit 1;
    else
        reg='Name: '
        name=$(grep "$reg" "$spec" |sed "s/$reg//" | sed "s/ //g")
        reg='Version: '
        vers=$(grep "$reg" "$spec" |sed "s/$reg//" | sed "s/ //g")
        echo "Found spec $spec: name $name version $vers"
    fi
else
    spec=$1.spec
    name="$1"
fi

if [ -z "$2" ]; then
    if [ -z "$vers" ]
    then
        echo "You didn't specify a version to build";
        exit 1;
    fi
else
    vers="$2"
    echo "Using spec $spec: name $name version $vers"
fi

grep -E 'Fedora|release 6' /etc/redhat-release >& /dev/null
if [ $? -eq 0 ]
then
  myrpmbasedir=$HOME/rpmbuild
else
  myrpmbasedir=/usr/src/redhat
fi

rpmbasedir=${BDISTRPMBASEDIR:-$myrpmbasedir}

echo "----> Building rpm for $name"
src_dir_main="$rpmbasedir/SOURCES/"
src_dir="$rpmbasedir/SOURCES/${name}-${vers}"
echo "----> Using $src_dir"
mkdir -pv "$src_dir"

# delete older versions of the rpm since there's no point having old
# versions in there when we still have the src.rpms in the SRPMS dir
echo "----> Cleaning up older packages"
find "$rpmbasedir/RPMS" -name "${name}-[0-9]\*" -exec rm -vf {} \;

echo "----> Copying files"
cp -var base.sh csub.py epilogue.sh makecsub.py "$src_dir"

# if there's a directory containing the source, as there will be
# for all our own packages, then delete any .tar.gz file that may exist
# for the package and create a new one.
echo "----> Creating new tar"
if [ -d "$src_dir" ] ;then
   rm -f "$src_dir.tar.gz"
   cd "$src_dir_main"
   tar zcvf "${name}-${vers}.tar.gz" "${name}-${vers}"
   cd -
fi


echo "----> Building the package"

## -ba: source and binary
## no debuginfo
rpmbuild --define "_topdir $rpmbasedir" -ba --without debuginfo "$spec"
ec=$?

echo "----> Cleanup"
# if there is a directory, then delete the .tar.gz again
if [ -d "${src_dir}" ] ;then
   rm -vf "${src_dir}.tar.gz"
fi

exit $ec
