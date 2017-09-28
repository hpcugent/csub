#!/bin/bash

# Test script for csub

testdir=`dirname $0`

# define required $VSC_* environment variables
export VSC_SCRATCH_NODE=/tmp/$USER/local
export VSC_SCRATCH=/tmp/$USER

# make sure fake 'qsub' command is in place (should be in same directory as this script)
qsub=`which qsub`
if [ $qsub != $testdir/qsub ]; then
    echo "ERROR: unexpected 'qsub' command found at $qsub (!= $testdir/qsub)" >&2
    exit 1
fi

# submit checkpointed 'job'
./csub --shared -s $testdir/count.sh --job_time=0:0:20 --no_cleanup_chkpt
ec=$?
if [ $ec -ne 0 ]; then
    echo "ERROR: csub failed to run" >&2
    exit $ec
fi

# wait until job.complete file is created
# count.sh needs 150s to complete, csub only checks once a minute => 2 checkpoints expected
timeout_secs=240
timeout $timeout_secs bash -c -- "while [ ! -f /tmp/$USER/chkpt/*/job.complete ]; do date; sleep 10; done"
ec=$?
# dump debug info if timeout was triggered
if [ $ec -ne 0 ]; then
    find /tmp/$USER/chkpt
    echo "stdout"
    cat /tmp/$USER/chkpt/*/count.sh.*.base.out
    cat /tmp/$USER/chkpt/*/count.sh.*.[0-9A-Za-z][0-9A-Za-z].out
    echo "stderr"
    cat /tmp/$USER/chkpt/*/count.sh.*.base.err
    echo "ERROR: job.complete file was not found after waiting $timeout_secs seconds..." >&2
    exit 1
fi

ls -l /tmp/$USER/chkpt/*/job.normal /tmp/$USER/chkpt/*/job.complete
if [ $? -ne 0 ]; then
    echo "ERROR: Expected job.normal and job.complete files not found in /tmp/$USER/chkpt/*" >&2
    exit 1
fi

start_count=`cat /tmp/$USER/chkpt/*/checkpoint/start.count`
if [ ${start_count:-1} -ne 0 ]; then
    echo "ERROR: Unexpected start count (should be 0): $start_count" >&2
    exit 1
fi
chkpt_count=`cat /tmp/$USER/chkpt/*/checkpoint/chkpt.count`
if [ ${chkpt_count:-1} -ne 2 ]; then
    echo "ERROR: Unexpected chkpt count (should be 2): $chkpt_count" >&2
    exit 1
fi

# counts from 0 to 149 should be there in the job output file
line_cnt=`cat /tmp/$USER/chkpt/*/count.sh.*.[0-9A-Za-z][0-9A-Za-z].out | wc -l`
if [ ${line_cnt:-1} -ne 150 ]; then
    echo "ERROR: Unexpected line count (should be 150): $line_cnt" >&2
    exit 1
fi
for n in `seq 0 149`; do
    grep "^$n " /tmp/$USER/chkpt/*/count.sh.*.[0-9A-Za-z][0-9A-Za-z].out
    if [ $? -ne 0 ]; then
        echo "ERROR: No output line starting with '$n ' found in output file" >&2
        exit 1
    fi
done

# stderr output file should be empty
ls -s /tmp/$USER/chkpt/*/count.sh.*.[0-9A-Za-z][0-9A-Za-z].err | grep '^0 '
if [ $? -ne 0 ]; then
    echo "ERROR: stderr output file is not empty" >&2
    exit 1
fi

echo "All tests passed!"
