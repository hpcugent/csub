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
## this is the basic script that does it all
## (no need for /bin/bash, is taken care of by BASEHEADER)
##

DMTCP_COMMAND=dmtcp_command
DMTCP_COORDINATOR=dmtcp_coordinator
DMTCP_LAUNCH=dmtcp_launch
DMTCP_RESTART=dmtcp_restart

PORTFILE=portfile

# empty job_pids cache
job_pids_cache=""

# unset %(CSUB_SERVER)s, can cause trouble when csub
# submits to non-default cluster
# e.g. qsub sets PBS_SERVER value to compiled-in default
# which may cause next job to be submitted to wrong cluster
unset %(CSUB_SERVER)s

jobname=${%(CSUB_JOBNAME)s}
## jobname_stripped is set in BASEHEADER
scriptname="${jobname_stripped}.sh"
localdir="${%(CSUB_SCRATCH_NODE)s}/$jobname"

myecho () {
    echo "$1"
}

if [ -z "${%(CSUB_SCRATCH_NODE)s}" ]
then
    echo "%(CSUB_SCRATCH_NODE)s undefined"
    env | grep %(CSUB_ORG)s | sort
    exit 1
fi

%(prologue)s ${%(CSUB_JOBID)s} "" "" ${%(CSUB_JOBNAME)s} %(cleanup_chkpt)d

if [ $? -ne 0 ]
then
	echo "ERROR! Prologue script abnormal exit."
	exit 2
fi

if [ ! -d "$localdir" ]
then
    ## no result from prologue -> shared checkpoint dir
    myecho "No localdir $localdir found (No local checkpoint)"

    localdir=${%(CSUB_SCRATCH)s}/chkpt/$jobname

    # this directory should be created by csub
    if [ ! -d "$localdir" ]
    then
    	## initial array job?
    	localdir_initial=${%(CSUB_SCRATCH)s}/chkpt/$jobname_stripped
    	if [ ! -f "$localdir/%(chkptsubdir)s/chkpt.count" ] && [ -d "$localdir_initial" ]
    	then
    		# copy initial job directory for array jobs
    		cp -r "$localdir_initial" "$localdir"
    	else
        	## problem
        	myecho "No localdir $localdir found (No shared checkpoint)"
        	exit 3
        fi
    fi
else
	# copy script
	cp "${%(CSUB_SCRATCH)s}/chkpt/$jobname/$scriptname" "$localdir"
fi

chkdir="$localdir/%(chkptsubdir)s"
mkdir -p "$chkdir/"

chktarb="$%(CSUB_SCRATCH)s/chkpt/$jobname/%(chkptsubdir)s/job.localdir.tarball"
chklock="$chkdir/chkpt.lock"
chkstat="$chkdir/chkpt.status"
chkid="$chkdir/chkpt.count"

# set environment variable with location of checkpoint file
# can be used by user program to checkpoint itself
export CSUB_CHECKPOINT_DIR="$chkdir"
export CSUB_CHECKPOINT_FILE=`ls $chkdir/*.dmtcp 2> /dev/null`
# initialize env variable for PID of process to be checkpointed
export CSUB_MASTER_PID_FILE="$chkdir/csub_master_pid"
# file to be touched/written if user kills the process
export CSUB_KILL_ACK_FILE="$chkdir/script_killed_by_user"
# script to be used by user to checkpoint
export CSUB_USER_CHKPT_SCRIPT="$chkdir/%(user_chkpt_script_file)s"

jobout="$localdir/$jobname.out"
joberr="$localdir/$jobname.err"

chkreout="$chkdir/chkpt.restart.out"
chkrecount="$chkdir/chkpt.restart.count"
chkrestat="$chkdir/chkpt.restart.status"
crcountmax=10

startcount="$chkdir/start.count"
stcountmax=5

chkslint=60
chksltot=%(job_time)d

chkprestage="$chkdir/prestage"
chkpoststage="$chkdir/poststage"

timestamp_latest_checkpoint() {
    # determine timestamp of most recent checkpoint (0 if no checkpoint files are found)
    # note: percent and newline must be escaped since this script is templated by Python!
    timestamp=`find $chkdir -maxdepth 1 -name '*.dmtcp' -printf '%%T@\\n' | sort -n | tail -1 | cut -f1 -d.`
    echo ${timestamp:-0}
}

epilogue () {
	# replaced either by actual epilogue or a simple echo commented out
	%(epilogue)s ${%(CSUB_JOBID)s} "" "" ${%(CSUB_JOBNAME)s} %(cleanup_chkpt)d
	if [ $? -ne 0 ]
	then
		myecho "ERROR! Epilogue script abnormal exit."
		exit 4
	fi
}

endjob () {
    touch job.normal
    if [ -f $chkbaseout ]
    then
        cat $chkbaseout >> $chkbaseout.all
    fi
    if [ -f $chkbaseerr ]
    then
        cat $chkbaseerr >> $chkbaseerr.all
    fi
}

resubmit () {
    fun=resubmit
    myecho
    myecho "begin $fun `date`"

    myexit=0
    ## resubmit this job (-N is required for array jobs!)
    ## the rest of this job should finish before all else
    out=`qsub -N $jobname -q $%(CSUB_QUEUE)s -o $chkbaseout -e $chkbaseerr -W depend=afterok:$%(CSUB_JOBID)s "$chkdir/base"`
    if [ $? -gt 0 ]
    then
        myecho "Job resubmit failed."
        myecho "Job resubmit output): $out"
        sleep 5
        out=`qsub -N $jobname -q $%(CSUB_QUEUE)s -o $chkbaseout -e $chkbaseerr -W depend=afterok:$%(CSUB_JOBID)s "$chkdir/base"`
        if [ $? -gt 0 ]
        then
            myecho "Job resubmit failed again."
            myecho "Job resubmit output: $out"
        else
            myecho "Job resubmit succesful second time."
            myecho "Job resubmit output: $out"
            ## rely on epilogue for backup
            myexit=1
        fi
    else
        myecho "Job resubmit succesful."
        myecho "Job resubmit output: $out"
        ## rely on epilogue for backup
        myexit=1
    fi


    myecho "end $fun `date`"
    myecho "EXITING BASE `date` $%(CSUB_JOBID)s"
    myecho

    endjob

    if [ $myexit -gt 0 ]
    then
    	epilogue
        exit 0
    fi
}

restart () {
    fun=restart
    myecho
    myecho "begin $fun `date`"
    ## sanity check
    for f in $chkid
    do
      if [ ! -f "$f" ]
      then
	  myecho "File $f missing"
	  return 0
      fi
    done

    chkptid=`cat $chkid`

    ## failure retry
    if [ -f "$chkrecount" ]
    then
    	crcount=`cat "$chkrecount"`
    	if [ $crcount -gt $crcountmax ]
	    then
	       myecho "No more retries (max: $crcountmax). Giving up."
	       endjob
	       exit 10
	    fi
    else
	   crcount=0
    fi

    # resume from checkpoint
    # wait until resume is actually complete via lockfile
    rm -f "$chkrestat"
    rm -f "$chklock"
    lockfile "$chklock"
    # using --new-coordinator doesn't seem to work, so start DMTCP coordinator ourselves as daemon and use that
    $DMTCP_COORDINATOR --daemon --coord-logfile "$chkdir/coord.log.$$" --coord-port 0 --port-file "$chkdir/$PORTFILE" --ckptdir $chkdir --exit-on-last --interval 0
    # give DMTCP coordinator some time to start...
    sleep 3
    coord_port=$(cat "$chkdir/$PORTFILE")
    myecho "DMTCP coordinator port: $coord_port"
    $DMTCP_RESTART --coord-port $coord_port `find $chkdir -name '*.dmtcp'` &
    script_pid=$!
    myecho "PID of relaunched script: $script_pid"
    # check status of relaunched script shortly after
    sleep 5
    kill -0 $script_pid 2> /dev/null
    if [ $? -eq 0 ]; then
        echo OK > "$chkrestat" && rm -f "$chklock"
    else
        echo FAILURE > "$chkrestat" && rm -f "$chklock"
    fi
    lockfile "$chklock"
    rm -f "$chklock"

	echo $script_pid > $CSUB_MASTER_PID_FILE

    crstat='UNKNOWN'
    if [ -f "$chkrestat" ]
    then
        crstat=`cat "$chkrestat"`
        rm -Rf "$chkrestat"
    else
        myecho "Restart status file $chkrestat not found. Is this a restart failure?"
        sleep 5
        kill -0 $script_pid 2> /dev/null
        if [ $? -eq 0 ]
        then
            myecho "Restart status check: Process running."
            crstat='OK'
        else
            myecho "Restart status check: Process not running."
            crstat='FAILURE'
        fi
    fi

    chkptid=$(($chkptid + 1))

    case $crstat in
	OK)
	    myecho "Succesful restart main id $chkptid restart nr $crcount at `hostname`"
	    echo $chkptid > $chkid
	    rm -f "$chkrecount"
	    cleanup_after_restart=%(cleanup_after_restart)d
	    if (( $cleanup_after_restart ))
	    then
	    	myecho "Cleaning up checkpoint file(s) and tarball after successful restart..."
	    	rm "$chkdir/*.dmtcp" "$chktarb"
	    fi
	    ;;
	FAILURE)
	    crcount=$(($crcount + 1))
	    echo $crcount > $chkrecount

	    myecho "Failed restart restart main id $chkptid restart nr $crcount of $crcountmax at `hostname`"
	    myecho "Begin of restart output"
	    cat $chkreout
	    myecho "End of restart output"
	    # double percent character for module operation, because this script is pushed through Python string formatting!
	    if [ $(($crcount%%2)) -eq 1 ]
            then
	        ## retry start
	        myecho "Attempt to restart"
		    restart
	    else
	        myecho "Attempt to resubmit"
	        resubmit
	    fi
	    ;;
	*)
	    ## should not happen
	    myecho "Unknown restart state: $crstat"
	    ;;
    esac
    myecho "end $fun `date`"
    myecho
}

firststart () {
    fun=firststart
    myecho
    myecho "begin $fun `date`"

    ## failure retry
    if [ -f $startcount ]
    then
        ls -l $startcount
    	stcount=`cat $startcount`
    	myecho "start attempt $stcount failed, retrying..."
    	stcount=$(($stcount+1))
    	if [ $stcount -ge $stcountmax ]
	    then
	       myecho "Failed to start job, even after $stcountmax tries. Giving up."
	       endjob
	       exit 20
	    fi
    else
        myecho "starting"
    	stcount=0
	fi
	echo $stcount > $startcount

    echo 0 > $chkid
    if [ -f "$chkprestage" ]
    then
	   "$chkprestage"
    fi
    $DMTCP_LAUNCH --coord-logfile "$chkdir/coord.log.$$" --interval 0 --ckptdir "$chkdir" --new-coordinator --port-file $chkdir/$PORTFILE bash -c "./${scriptname} > ${jobout} 2> ${joberr}" &
    script_pid=$!
    myecho "PID of running script: $script_pid"
    # check status of process shortly after launch
    sleep 5
    kill -0 $script_pid 2> /dev/null
    if [ $? -eq 0 ]; then
    	echo $script_pid > "$CSUB_MASTER_PID_FILE"
    else
    	echo "PID of process running $scriptname not found... Exiting!"
    	exit 1
    fi
    myecho "end $fun `date`"
    myecho
}

chkptsleep () {
    fun=chkptsleep
    myecho
    myecho "begin $fun `date`"
    ## else, sleep
    sleeping=0
    while [ $sleeping -lt $chksltot ]
    do
      # reverse 1s for actual check
      sleep $(($chkslint-1))
      # exit sleep loop as soon as process is no longer there
      kill -0 $script_pid 2> /dev/null
      if [ $? -ne 0 ]; then
        return
      fi
      sleeping=$(($sleeping+$chkslint))
    done
    myecho "end $fun `date`"
    myecho
}

makechkpt () {
    fun=makechkpt
    myecho
    myecho "begin $fun `date`"
    chkfile_curTime=`timestamp_latest_checkpoint`
    myecho "chkfile_lastTime: $chkfile_lastTime; chkfile_curTime: $chkfile_curTime"
    if [ "$chkfile_curTime" -gt "$chkfile_lastTime" ]; then
        myecho "Recent checkpoint(s) found (timestamp: `date -d @$chkfile_curTime`, time now: `date`):"
        kill -0 $script_pid 2> /dev/null
        if [ $? -eq 0 ]; then
            echo "Process (pid: $script_pid) still running, killing it..."
            kill -9 $script_pid
        fi
        myecho "Using checkpoint found, not checkpointing again."
    else
        myecho "No recent checkpoint found, so checkpointing..."
        coord_port=$(cat "$chkdir/$PORTFILE")
        myecho "DMTCP coordinator port: $coord_port"
        # checkpoint & wait until checkpointing is done
        # note: specified kill mode '%(CSUB_KILL_MODE)s' is blatently ignored here,
        # DMTCP does not support sending a particular signal
        $DMTCP_COMMAND --port $coord_port --bcheckpoint
        # kill processes & DMTCP coordinator
        $DMTCP_COMMAND --port $coord_port --quit
    fi
    myecho "end $fun `date`"
    myecho
}

endofjob () {
    fun=endofjob
    myecho
    myecho "begin $fun `date`"
    # Add stdout and stderr to central files
    if [ -f "$chkpoststage" ]
    then
       tmpdir=$(mktemp -d)
       cp -a "$chkpoststage" "$tmpdir/poststage"
       chmod +x "$tmpdir/poststage"
       if (( %(cleanup_chkpt)d ))
       then
       		rm -Rf "$chkdir"
       fi
       "$tmpdir/poststage"
    else
       if (( %(cleanup_chkpt)d ))
       then
       		rm -Rf "$chkdir"
       fi
    fi
    endjob

    touch job.complete

    myecho "end $fun `date`"
    myecho
}

###############
## Real work
###############

myecho
myecho "BEGIN base $%(CSUB_JOBID)s `date`"
myecho

# check whether DMTCP is available
which $DMTCP_COMMAND > /dev/null
if [ $? -ne 0 ]; then
    myecho "ERROR: DMTCP is not available, aborting job"
    endjob
    exit 30
fi

cd "$localdir"
if [ $? -gt 0 ]
then
    myecho "Can't cd into localdir $localdir"
    exit 1
fi

rm -f job.normal
rm -f job.complete

myecho "Checking for available checkpoints @ ${chkdir}..."
chkfile_lastTime=`timestamp_latest_checkpoint`
if [ $chkfile_lastTime -eq 0 ]; then
    myecho "No checkpoints found, first start..."
    firststart
else
    myecho "Found recent checkpoint (timestamp: `date -d @$chkfile_lastTime`), restarting..."
    restart
fi

kill -0 $script_pid 2> /dev/null
if [ $? -ne 0 ]
then
    myecho "Process not running before sleep."
fi

chkptsleep

# check whether job is still running or finished
kill -0 $script_pid 2> /dev/null
if [ $? -eq 0 ]; then
  makechkpt
  resubmit # exits
else
  # check if job was killed by user after checkpoint
  if [ -f "$CSUB_KILL_ACK_FILE" ]
  then
  	makechkpt
  	rm "$CSUB_KILL_ACK_FILE"
  	if [ $? -ne 0 ]
  	then
  		myecho "ERROR! Failed to remove file $CSUB_KILL_ACK_FILE. Not resubmitting after checkpoint."
  		exit 1
  	fi
  	resubmit # exits
  else
    # job not found, and not killed by user, so done
  	myecho "Process not running after sleep."
  	endofjob
  fi
fi

epilogue

myecho
myecho "END base $%(CSUB_JOBID)s `date`"
myecho
