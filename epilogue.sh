#!/bin/bash
##
# Copyright 2009-2016 Ghent University
#
# This file is part of csub,
# originally created by the HPC team of Ghent University (http://ugent.be/hpc/en),
# with support of Ghent University (http://ugent.be/hpc),
# the Flemish Supercomputer Centre (VSC) (https://vscentrum.be/nl/en),
# the Flemish Research Foundation (http://www.fwo.be/en),
# and the Department of Economy, Science and Innovation (EWI) (http://www.ewi-vlaanderen.be/en).
#
# http://github.com/hpcugent/csub
#
# csub is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as
# published by the Free Software Foundation, either version 2 of
# the License, or (at your option) any later version.
#
# csub is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Library General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with csub. If not, see <http://www.gnu.org/licenses/>.
#
##
##
## This is an epilogue/prologue checkpoint script
##
jobid="$1"
jobname="${4}"
cleanup_chkpt=$5

cmd=`basename $0`

if [ "x$jobid" == "x" ] || [ "x$jobname" == "x" ]
then
    echo "ERROR! Required arguments job id and job name not passed to ${cmd}."
    echo "list of arguments: ${*}"
    exit 1 # abort exit code for Torque
fi


FLAVOUR=UNKNOWN

myecho () {
    if [ -d "$chkptdir" ]
    then
       echo $1 | tee -a $chkptdir/epi_pro.logue
    else
	   echo $1
    fi
}

logg () {
    myecho "$FLAVOUR $jobname `date`"
}

begg () {
    myecho ""
    myecho "## BEGIN USER $FLAVOUR `date` jobid $jobid `hostname`"
    myecho ""
}

## always exit 0, otherwise jobs will be deferred
endd () {
    myecho ""
    myecho "## END  USER $FLAVOUR `date` jobid $jobid"
    myecho ""
    exit 0
}

cleanuplocal () {
    ## cleanup localdir
    ls -l
    cd $CURRENTDIR
    rm -Rf $localdir
    if [ $? -gt 0 ]
    then
	   myecho "Removing localdir $localdir failed."
    fi

}

pack () {
    fun=pack
    myecho
    myecho "begin $fun `date`"
    ls -lrt
    time tar -c $taropts -f $tarb . 2>&1
    md5sum $tarb
    if [ $? -gt 0 ]
    then
    	"Packing failed. Cmd used: tar -c $taropts -f $tarb ."
	   cleanuplocal
	   endd
    fi
    myecho "end $fun `date`"
    myecho
}

unpack () {
    fun=unpack
    myecho
    myecho "begin $fun `date`"
    ls -lrt
    md5sum $tarb
    time tar -x $taropts -f $tarb 2>&1
    if [ $? -gt 0 ]
    then
       "Unpacking failed. Cmd used: tar -x $taropts -f $tarb"
	   cleanuplocal
	   endd
    fi
    myecho "end $fun `date`"
    myecho
}

remove_dir () {
	dir=$1
	# this doesn't work on NFS, because (base script)job stdout and stderr are there
	# files are still open when rm is called, and NFS doesn't allow removal of open files
	rm -Rf $dir
	exit_code=$?
	if [ $exit_code -gt 0 ]
	then
		myecho "Removing dir $dir failed (exit code: ${exit_code})."
        myecho "We know this will fail on NFS, so retrying through $%(CSUB_O_HOST)s (different filesystem)."
        ssh $%(CSUB_O_HOST)s rm -Rf $dir
        if [ $? -gt 0 ]
        then
        	myecho "Removing dir $dir through $%(CSUB_O_HOST)s failed. Giving up."
        fi
	fi
}

case $cmd in
    epilogue)
        FLAVOUR=epilogue
	;;
    prologue)
        FLAVOUR=prologue
	;;
    *)
        myecho "Undefined. Use epilogue or prologue only. Exiting..."
	exit 0
	;;
esac


## set primitive environment
export USER=`whoami`
export HOME=`getent passwd $USER |cut -d ':' -f 6`
. %(CSUB_PROFILE_SCRIPT)s

##
## set some general values
##


if [ -z "$%(CSUB_SCRATCH_NODE)s" ]
then
    echo "%(CSUB_SCRATCH_NODE)s undefined"
    env|sort|grep %(CSUB_ORG)s
    exit 1
fi

localdir=$%(CSUB_SCRATCH_NODE)s/$jobname
mkdir -p $localdir/checkpoint
if [ $? -gt 0 ]
then
    myecho "Creating localdir $localdir/checkpoint failed"
    endd
fi


begg

chkptdir=$%(CSUB_SCRATCH)s/chkpt/$jobname

## destination tarball
tarb="$chkptdir/checkpoint/job.localdir.tarball"
## no compression, too slow
## if adjusted, do so in csub too!!
taropts=" -v -p"

logg

CURRENTDIR=`pwd`

cd $localdir


case $FLAVOUR in
    prologue)
        if [ ! -f "${tarb}.ok" ]
        then
        	# if $tarb.ok was not found, maybe we're running the first ever prologue for an array job
        	chkptdir_initial=`echo $chkptdir | sed 's/-[0-9]\\+$//g'`
        	tarb_initial=`echo $tarb | sed 's@-[0-9]\\+/checkpoint@/checkpoint@g'`
        	if [ ! -f $chkptdir_initial/checkpoint/chkpt.count ] && [ -f "${tarb_initial}.ok" ] && [ -f ${tarb_initial} ]
        	then
        		tarb=$tarb_initial
        	else
            	## epilogue failed in intermediate tar (eg timeout)
            	myecho "No tarball .ok file found. Won't start prologue."
            	endd
            fi
        fi

	   if [ -f "$tarb" ]
       then
	       unpack
	   else
	       myecho "No chkpt file $tarb found. No unpacking."
	   fi
	   ;;
    epilogue)
        if [ ! -f "job.normal" ]
        then
            ## abnormal job end, eg qdel
            myecho "Job completed. But no normal job end. Removing all local files"
        else
           mkdir -p "$chkptdir/checkpoint"
           if [ $? -gt 0 ]
           then
               myecho "Creating chkptdir $chkptdir/checkpoint failed"
               endd
           fi

    	   if [ ! -f "job.complete" ]
	       then
	           ## remove tarball ok file
	           rm -f "$tarb.ok"
	           pack
               ## set tarball ok file
	           touch "$tarb.ok"
	       else
	           myecho "Job completed. No packing."
	           if (( $cleanup_chkpt ))
	           then
		           myecho "Removing chkptdir $chkptdir"
		           remove_dir "$chkptdir"

            	   # last array job should try and remove initial job directory
               	   # this directory contains all info on checkpointing of different array jobs

	               chkptdir_initial=`echo $chkptdir | sed 's/-[0-9]\\+$//g'`
    	           dir=`dirname $chkptdir_initial`
        	       base=`basename $chkptdir_initial`
            	   ls "$dir" | grep "^${base}-[0-9]\+$" >& /dev/null
	               if [ $? -ne 0 ]
    	           then
        	       		remove_dir ${chkptdir_initial}
            	   fi
               else
               		# 	copy back stdout/stderr of job into chkpt subdir (useful for debugging)
               		cp "$localdir/${jobname}.out" "$localdir/${jobname}.err" "$chkptdir"
               fi
	       fi
	   fi
	   cleanuplocal

	   ;;
esac

cd "$CURRENTDIR" 2> /dev/null

endd
