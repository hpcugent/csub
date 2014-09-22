##
# Copyright 2009-2014 Ghent University
#
# This file is part of csub,
# originally created by the HPC team of Ghent University (http://ugent.be/hpc/en),
# with support of Ghent University (http://ugent.be/hpc),
# the Flemish Supercomputer Centre (VSC) (https://vscentrum.be/nl/en),
# the Hercules foundation (http://www.herculesstichting.be/in_English)
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

# empty job_pids cache
job_pids_cache=""

# unset %(CSUB_SERVER)s, can cause trouble when csub
# submits to non-default cluster
# e.g. qsub sets PBS_SERVER value to compiled-in default
# which may cause next job to be submitted to wrong cluster
unset %(CSUB_SERVER)s

# make sure qsub is available
module load jobs

jobname=${%(CSUB_JOBNAME)s}
## jobname_stripped is set in BASEHEADER
scriptname="${jobname_stripped}.sh"
localdir=$%(CSUB_SCRATCH_NODE)s/$jobname

myecho () {
    echo "$1"
}

if [ -z "$%(CSUB_SCRATCH_NODE)s" ]
then
    echo "%(CSUB_SCRATCH_NODE)s undefined"
    env|sort|grep %(CSUB_ORG)s
    exit 1
fi

%(prologue)s $%(CSUB_JOBID)s "" "" $%(CSUB_JOBNAME)s %(cleanup_chkpt)d
if [ $? -ne 0 ]
then
	echo "ERROR! Prologue script abnormal exit."
	exit 1
fi

if [ ! -d $localdir ]
then
    ## no result from prologue -> shared checkpoint dir
    myecho "No localdir $localdir found (No local checkpoint)"

    localdir=$%(CSUB_SCRATCH)s/chkpt/$jobname

    # this directory should be created by csub
    if [ ! -d $localdir ]
    then
    	## initial array job?
    	localdir_initial=$%(CSUB_SCRATCH)s/chkpt/$jobname_stripped
    	if [ ! -f $localdir/%(chkptsubdir)s/chkpt.count ] && [ -d $localdir_initial ]
    	then
    		# copy initial job directory for array jobs
    		cp -r $localdir_initial $localdir
    	else
        	## problem
        	myecho "No localdir $localdir found (No shared checkpoint)"
        	exit 1
        fi
    fi
else
	# copy script
	cp $%(CSUB_SCRATCH)s/chkpt/$jobname/$scriptname $localdir
fi

chkdir="$localdir/%(chkptsubdir)s"
mkdir -p $chkdir/

chkfile="$chkdir/chkpt.file"
chktarb="$%(CSUB_SCRATCH)s/chkpt/$jobname/%(chkptsubdir)s/job.localdir.tarball"
chklock="$chkdir/chkpt.lock"
chkstat="$chkdir/chkpt.status"
chkid="$chkdir/chkpt.count"

# set environment variable with location of checkpoint file
# can be used by user program to checkpoint itself
export CSUB_CHECKPOINT_FILE="$chkfile"
# initialize env variable for PID of process to be checkpointed
export CSUB_MASTER_PID_FILE="$chkdir/csub_master_pid"
# file to be touched/written if user kills the process
export CSUB_KILL_ACK_FILE="$chkdir/script_killed_by_user"
# script to be used by user to checkpoint
export CSUB_USER_CHKPT_SCRIPT="$chkdir/%(user_chkpt_script_file)s"

chkfile_lastTime=0
if [ -f $chkfile ]
then
	# double percent, based this script is pushed through Python
	chkfile_lastTime=`stat -c %%Y $chkfile`
fi

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

chksave=%(chkpt_save_opt)s

cr_restart_restore="--no-restore-pid"

chkprestage="$chkdir/prestage"
chkpoststage="$chkdir/poststage"

epilogue () {
	# replaced either by actual epilogue or a simple echo commented out
	%(epilogue)s $%(CSUB_JOBID)s "" "" $%(CSUB_JOBNAME)s %(cleanup_chkpt)d
	if [ $? -ne 0 ]
	then
		myecho "ERROR! Epilogue script abnormal exit."
		exit 1
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

mypid () {
	# find match between pids of this job's children
	# and pids of processes excuting the script
    script_pids=`/sbin/pidof -x $scriptname`
    if [ -z $job_pids_cached ]
    then
    	job_pids_cached=`pstree -p $$ | tr '\\\\n' ' ' | sed 's/[^0-9]*\\([0-9]\\+\\)[^0-9]*/\\\\1 /g'`
    fi
    for job_pid in $job_pids_cached;
    do
    	for script_pid in $script_pids;
    	do
    		if [ $job_pid -eq $script_pid ];
    		then
    			echo $job_pid;
    			return;
    		fi;
    	done;
    done

    # no match found (job done?)
    echo 0
}

resubmit () {
    fun=resubmit
    myecho
    myecho "begin $fun `date`"

    myexit=0
    ## resubmit this job (-N is required for array jobs!)
    ## the rest of this job should finish before all else
    out=`module load jobs; qsub -N $jobname -q $%(CSUB_QUEUE)s -o $chkbaseout -e $chkbaseerr -W depend=afterok:$%(CSUB_JOBID)s < $chkdir/base`
    if [ $? -gt 0 ]
    then
        myecho "Job resubmit failed."
        myecho "Job resubmit output): $out"
        sleep 5
        out=`module load jobs; qsub -N $jobname -q $%(CSUB_QUEUE)s -o $chkbaseout -e $chkbaseerr -W depend=afterok:$%(CSUB_JOBID)s < $chkdir/base`
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
      if [ ! -f $f ]
      then
	  myecho "File $f missing"
	  return 0
      fi
    done

    chkptid=`cat $chkid`

    ## failure retry
    if [ -f $chkrecount ]
    then
    	crcount=`cat $chkrecount`
    	if [ $crcount -gt $crcountmax ]
	    then
	       myecho "No more retries (max: $crcountmax). Giving up."
	       endjob
	       exit 10
	    fi
    else
	   crcount=0
    fi

    ## cr_restart
    ## wait until restart is really done
    ## nice trick from KennethHoste
    rm -f $chkrestat
    rm -f $chklock
    lockfile $chklock
    cr_restart $cr_restart_restore --run-on-success="echo OK > $chkrestat && rm -f $chklock" --run-on-failure="echo FAILURE > $chkrestat && rm -f $chklock" -f $chkfile >& $chkreout &
    lockfile $chklock
    rm -f $chklock

    pid=`mypid`
	echo $pid > $CSUB_MASTER_PID_FILE

    crstat='UNKNOWN'
    if [ -f $chkrestat ]
    then
        crstat=`cat $chkrestat`
        rm -Rf $chkrestat
    else
        myecho "Restart status file $chkrestat not found. Is this a restart failure?"
        sleep 5
        pid=`mypid`
        if [ $pid -eq 0 ]
        then
            myecho "Restart status check: Process not running."
            crstat='FAILURE'
        else
            myecho "Restart status check: Process running."
            crstat='OK'
        fi
    fi

    chkptid=$(($chkptid + 1))

    case $crstat in
	OK)
	    myecho "Succesful restart main id $chkptid restart nr $crcount at `hostname`"
	    echo $chkptid > $chkid
	    rm -f $chkrecount
	    cleanup_after_restart=%(cleanup_after_restart)d
	    if (( $cleanup_after_restart ))
	    then
	    	myecho "Cleaning up checkpoint and tarball after successful restart..."
	    	rm $chkfile $chktarb
	    fi
	    ;;
	FAILURE)
	    crcount=$(($crcount + 1))
	    echo $crcount > $chkrecount

	    myecho "Failed restart restart main id $chkptid restart nr $crcount of $crcountmax at `hostname`"
	    myecho "Begin of restart output"
	    echo "cr_restart $cr_restart_restore --run-on-success=\"echo OK \> $chkrestat \&\& rm -f $chklock\" --run-on-failure=\"echo FAILURE \> $chkrestat \&\& rm -f $chklock\" -f $chkfile"
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
	    myecho "cr_restart state unknown ($crstat)."
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
    if [ -f $chkprestage ]
    then
	   $chkprestage
    fi
    cr_run -- ./$scriptname > ${jobout} 2> ${joberr} &
    ## should be immediate
    ## i'm not sure what's fastest: starting in background or starting with cr_run
    sleep 5
    pid=`mypid`
    if [ $pid -gt 0 ]
    then
    	echo $pid > $CSUB_MASTER_PID_FILE
    else
    	echo "PID of process started with cr_run running $scriptname not found... Exiting!"
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
      pid=`mypid`
      if [ $pid -eq 0 ]
      then
	  	return $pid
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
    # double percent, based this script is pushed through Python
    if [ -f $chkfile ]
    then
    	chkfile_curTime=`stat -c %%Y $chkfile`
    else
    	chkfile_curTime=0
    fi
    myecho "chkfile_lastTime: $chkfile_lastTime; chkfile_curTime: $chkfile_curTime"
    if [ -f $chkfile ] && [ $chkfile_curTime -gt $chkfile_lastTime ]
    then
    	myecho "Recent checkpoint found (time now: `date`):"
    	ls -l $chkfile
    	pid=`mypid`
    	if [ $pid -gt 0 ]
    	then
    		"Process (pid: $pid) still running, killing it..."
    		kill $pid
    	fi
    	myecho "Using checkpoint found, not checkpointing again."
    else
    	myecho "No recent checkpoint found, so checkpointing..."
    	if [ "x%(CSUB_KILL_MODE)s" == "xterm" ]
    	then
    		cr_checkpoint --term --save-$chksave $pid -f $chkfile
    		sleep 30
    		kill -9 $pid
    	else
    		cr_checkpoint --kill --save-$chksave $pid -f $chkfile
    	fi
    fi
    myecho "end $fun `date`"
    myecho
}

endofjob () {
    fun=endofjob
    myecho
    myecho "begin $fun `date`"
    # Add stdout and stderr to central files
    if [ -f $chkpoststage ]
    then
       cp -a $chkpoststage /tmp/poststage
       chmod +x /tmp/poststage
       if (( %(cleanup_chkpt)d ))
       then
       		rm -Rf $chkdir
       fi
       /tmp/poststage
    else
       if (( %(cleanup_chkpt)d ))
       then
       		rm -Rf $chkdir
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

# check whether BLCR support is available
/sbin/lsmod | grep blcr >& /dev/null
if [ $? -ne 0 ]
then
	myecho "No BLCR support available here (`hostname`), aborting job."
	endjob
	exit 30
fi

cd $localdir
if [ $? -gt 0 ]
then
    myecho "Can't cd into localdir $localdir"
    exit 1
fi

rm -f job.normal
rm -f job.complete



if [ -f $chkfile ]
then
    restart
else
    firststart
fi

pid=`mypid`
if [ $pid -eq 0 ]
then
    myecho "Process not running before sleep."
fi

chkptsleep

pid=`mypid`

## check whether job is still running or finished
if [ $pid -gt 0 ]
then
  makechkpt
  resubmit # exits
else
  # check if job was killed by user after checkpoint
  if [ -f $CSUB_KILL_ACK_FILE ]
  then
  	makechkpt
  	rm $CSUB_KILL_ACK_FILE
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



