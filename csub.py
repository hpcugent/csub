#!/usr/bin/env python
##
# Copyright 2009-2015 Ghent University
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
#
"""
This is a python wrapper for checkpointed job submission
It is also a selfcontained jobscript
Requires torque >= 2.4.2 and BLCR

@author: Stijn De Weirdt (Ghent University)
@author: Kenneth Hoste (Ghent University)
@author: Jens Timmerman (Ghent University)
@author: Ward Poelmans (Ghent University)
"""

import os
import popen2
import re
import shutil
import sys

#
# ideally, changing the dictionary below should be sufficient
# to get csub working on your setup
# if you are using a scheduler which is currently not supported
# by csub, you should also add support for it in the following
# functions:
#             * get_job_name_spec
#             * gen_pro_epi_spec
#             * gen_base_header
#             * split_unique_script_name

csub_vars_map = {
    'CSUB_ARRAY_SEP': '-',  # array seperator, e.g. the '-' in job_name-1 (PBS)
    'CSUB_JOBID': 'PBS_JOBID',
    'CSUB_JOBNAME': 'PBS_JOBNAME',
    'CSUB_KILL_MODE': 'kill',
    'CSUB_O_HOST': 'PBS_O_HOST',
    'CSUB_ORG': 'VSC',
    'CSUB_PROFILE_SCRIPT': '/etc/profile.d/vsc.sh',
    'CSUB_QUEUE': 'PBS_QUEUE',
    'CSUB_SCHEDULER': 'PBS',
    'CSUB_SCRATCH_NODE': 'VSC_SCRATCH_NODE',
    'CSUB_SCRATCH': 'VSC_SCRATCH',
    'CSUB_SERVER': 'PBS_SERVER',
}


# These are filled with the makecsub.py script
EPILOGUE = ""
BASE = ""

PRESTAGELOCAL = """#!/bin/bash

# copy all files in this directory recursively
# no hidden files?
srcdir=%(srcdir)s
if [ -d  $srcdir ]
then
  cp -r $srcdir/* .
  if [ $? -gt 0 ]
  then
      echo "Copying failed ($srcdir to $PWD)"
      exit 1
  fi
else
    echo "Sourcedir $srcdir not found"
    exit 2
fi

"""

POSTSTAGELOCAL = """#!/bin/bash

# copy all files in this directory recursively
# no hidden files?
destdir=%(destdir)s/result.$%(CSUB_JOBNAME)s
mkdir -p $destdir

if [ -d  $destdir ]
then
  cp -r * $destdir
  if [ $? -gt 0 ]
  then
      echo "Copying failed ($PWD to $destdir)"
      exit 1
  fi
  # don't copy prologue and epilogue to result directory
  rm -f $destdir/prologue $destdir/epilogue
else
    echo "Destdir $destdir not found"
    exit 2
fi

"""

chkptdirbasebase = os.path.join(
    "%s" % (os.environ[csub_vars_map['CSUB_SCRATCH']]), "chkpt")
chkptsubdir = "checkpoint"
tarbfilename = 'job.localdir.tarball'
basescriptname = "base"


def usage():
    print """
    csub [opts] [-s jobscript]

    Options:
        -h or --help   Display this message

        -s        Name of jobscript used for job.
                Warning: The jobscript should not create it's own local temporary directories.

        -q    Queue to submit job in [default: scheduler default queue]

        -t     Array job specification (see -t in man qsub) [default: none]

        --pre     Run prestage script (Current: copy local files) [default: no prestage]

        --post    Run poststage script (Current: copy results to localdir/result.) [default: no poststage]

        --shared    Run in shared directory (no pro/epilogue, shared checkpoint) [default: run in local dir]

        --no_mimic_pro_epi    Do not mimic prologue/epilogue scripts [default: mimic pro/epi (bug workaround)]

        --job_time=<string>    Specify wall time for job (format: <hours>:<minutes>:<seconds>s, e.g. 3:12:47) [default: 10h]

        --chkpt_time=<string>    Specify time for checkpointing a job (format: see --job_time) [default: 15m]

        --cleanup_after_restart         Specify whether checkpoint file and tarball should be cleaned up after a successful restart (NOT RECOMMENDED!) [default: no cleanup]

        --no_cleanup_chkpt        Don't clean up checkpoint stuff in $%(CSUB_SCRATCH)s/chkpt after job completion [default: do cleanup]

        --resume=<string>        Try to resume a checkpointed job; argument should be unique name of job to resume [default: none]

        --chkpt_save_opt=<string>        Save option to use for cr_checkpoint (all|exe|none) [default: exe]

        --term_kill_mode        Kill checkpointed process with SIGTERM instead of SIGKILL after checkpointing [defailt: SIGKILL]

        --vmem=<string>        Specify amount of virtual memory required [default: none specified]"

""" % csub_vars_map

    sys.exit(0)


def get_job_name_spec(script):

    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":
        regname = re.compile("^\s*#PBS\s+-N\s+(?P<job_name>\S+)\s*$", re.MULTILINE).search(script)
        if regname:
            return regname.group('job_name')
        else:
            return None

    else:
        print "(get_job_name_spec) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


def get_wall_time(script):
    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":
        walltime_regexp = re.compile("^(#PBS -l walltime)=(?P<walltime>[0-9:]+)\s*(\S*)$", re.MULTILINE)
        walltime_list = [int(x) for x in walltime_regexp.search(script).group('walltime').split(':')]
        walltime = walltime_list[0] * 3600 + walltime_list[1] * 60 + walltime_list[2]
        return walltime
    else:
        print "(get_wall_time) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


def replace_walltime_str(script, wall_time_str):
    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":
        walltime_regexp = re.compile("^(#PBS -l walltime)=(?P<walltime>[0-9:]+)\s*(\S*)$", re.MULTILINE)
        return walltime_regexp.sub(r"\1=%s \3" % wall_time_str, script)
    else:
        print "(replace_walltime_str) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


def replace_vmem(script, vmem):
    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":
        vmem_regexp = re.compile("^(#PBS -l vmem)=(?P<vmem>.+)\s*(\S*)$", re.MULTILINE)
        return vmem_regexp.sub(r"\1=%s \3" % vmem, script)
    else:
        print "(replace_vmem) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


def gen_pro_epi_spec(pro_epi, pro_epi_script):

    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":
        if pro_epi == "prologue":
            return "#PBS -l prologue=%s" % (pro_epi, pro_epi_script)
        elif pro_epi == "epilogue":
            return "#PBS -l epilogue=%s" % (pro_epi, pro_epi_script)
        else:
            print "(gen_pro_epi_spec) Don't know how to handle \'%s\'." % pro_epi
            sys.exit(1)
    else:
        print "(gen_pro_epi_spec) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


def gen_wall_time_str(wall_time):

    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":
        wall_time_hours = int(wall_time / 3600)
        wall_time_mins = int(wall_time % 3600 / 60)
        wall_time_secs = int(wall_time % 3600 % 60)
        wall_time_str = "%d:%d:%d" % (wall_time_hours, wall_time_mins, wall_time_secs)
        return wall_time_str
    else:
        print "(gen_wall_time_str) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


def gen_base_header(localmap, script):

    localmap.update(csub_vars_map)

    req_keys = ['queue', 'wall_time', 'name', 'chkptdirbase',
                'prologue_header_spec', 'epilogue_header_spec']

    if any([(k not in localmap.keys()) for k in req_keys]):
        print """(gen_base_header) Not all required keys found in localmap (%s),
                 things will probably go wrong...""" % ','.join(req_keys)

    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":

        vmemregexp = re.compile("^\s*#PBS\s+-l\s+vmem")

        l_specs = ""
        reglspecs = re.compile("^\s*#PBS\s+-l\s+[^\n]*$", re.MULTILINE).findall(script)
        if reglspecs:
            l_specs = '\n'.join([x for x in reglspecs if (not re.compile("^\s*#PBS\s+-l\s+walltime").match(x))
                                 and (not vmemregexp.match(x))])
        localmap.update({'l_specs': l_specs})

        queue = localmap['queue']
        if queue:
            queue_spec = "#PBS -q %s" % queue
        else:
            queue_spec = ""
        localmap.update({'queue_spec': queue_spec})

        vmem = localmap['vmem']
        if vmem:
            vmem_spec = "#PBS -l vmem=%s" % vmem
        else:
            # fetch vmem spec from script (if any)
            vmem_spec = ""
            if reglspecs:
                vmems = [x for x in reglspecs if vmemregexp.match(x)]
                if len(vmems) > 0:
                    vmem_spec = vmems[0]

        localmap.update({'vmem_spec': vmem_spec})

        localmap.update({'wall_time_str': gen_wall_time_str(localmap['wall_time'])})

        txt = """#!/bin/bash
#PBS -l walltime=%(wall_time_str)s
%(queue_spec)s
#PBS -N %(name)s
#PBS -o %(chkptdirbase)s/%(name)s.base.out
#PBS -e %(chkptdirbase)s/%(name)s.base.err
%(epilogue_header_spec)s
%(prologue_header_spec)s
%(l_specs)s
%(queue_spec)s
%(vmem_spec)s

# job name without array id (if any)
jobname_stripped=%(name)s

chkbaseout=%(chkptdirbase)s/%(name)s.base.out
chkbaseerr=%(chkptdirbase)s/%(name)s.base.err
# append array id to stdout/stderr files if needed
CSUB_ARRAYID=""

if [[ $PBS_JOBNAME =~ "${jobname_stripped}%(CSUB_ARRAY_SEP)s[0-9]+" ]]
then
    arrayid=`echo $PBS_JOBNAME | sed 's/.*%(CSUB_ARRAY_SEP)s\([0-9]\+\)$/\\1/g'`
    chkbaseout=${chkbaseout}%(CSUB_ARRAY_SEP)s${arrayid}
    chkbaseerr=${chkbaseerr}%(CSUB_ARRAY_SEP)s${arrayid}
fi
        """ % localmap
        return txt
    else:
        print "(gen_base_header) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


# generate unique job name
# no need to include user id in unique name, because users can't see jobs of other users
def uniquescriptname(origname, txt):
    name = os.path.basename(origname)

    # fetch job name specified in job script (if any)
    name_in_script = get_job_name_spec(txt)
    if name_in_script:
        name = name_in_script

    import time
    import random

    # list of alpha-numeric characters: '0'-'9' (48-56), 'A'-'Z' (65-91), 'a'-'z' (97-123)
    alph = [chr(i) for i in range(48, 58) + range(65, 91) + range(97, 123)]

    # unique name formed by <job_name>.<timestamp>.<two random characters>
    return "%s.%s.%s" % (name, time.strftime("%Y%m%d_%H%M%S"), ''.join(random.sample(alph, 2)))


# split into actual script name (generated with uniquescriptname) and possible array id
def split_unique_script_name(name):

    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":

        r = re.compile("(?P<cleanname>\S+.[0-9]+_[0-9]+.\S\S)(%s(?P<arrayid>\d+))?" % csub_vars_map['CSUB_ARRAY_SEP'])
        m = r.match(name)
        if m:
            cleanname = m.group('cleanname')
            arrayid = m.group('arrayid')
            return (cleanname, arrayid)
        else:
            print "ERROR! Unexpected format of job name."
            sys.exit(1)
    else:
        print "ERROR! (in split_unique_script_name) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


# checks whether resuming job with given name might work
# return path of base script for job, or None if resuming will fail
def checkResume(name):

    chkptdirbase = os.path.join(chkptdirbasebase, name)
    # remove possible array id
    (cleanname, arrayid) = split_unique_script_name(name)

    # check for job checkpoint directory
    if not os.path.isdir(chkptdirbase):
        print "Job checkpoint directory (%s) not found..." % chkptdirbase
        return (None, None)
    else:
        print "# Job checkpoint directory found @ %s" % chkptdirbase
        # check for job script
        jobscript = os.path.join(chkptdirbase, "%s.sh" % cleanname)
        if not os.path.isfile(jobscript):
            print "Job script (%s) not found..." % jobscript
            return (None, None)
        else:
            print "# Job script found @ %s" % jobscript
            # check for tarball containing checkpoint and intermediary files of job
            # and for checkpoint file (no tarball in case of --shared)
            tarbfile = os.path.join(chkptdirbase, chkptsubdir, tarbfilename)
            tarbfilefound = os.path.isfile(tarbfile)
            chkptfile = os.path.join(chkptdirbase, chkptsubdir, "chkpt.file")
            chkptfilefound = os.path.isfile(chkptfile)

            if not tarbfilefound and not chkptfilefound:
                print "# Tarball for job (%s), which contains checkpoint and intermediate files, not found..." % tarbfile
                print "# Checkpoint file for job (%s) not found..." % chkptfile
                print "# This is ok if job was submitted with --shared."
                return (None, None)
            else:
                if tarbfilefound:
                    print "# Job tarball found @ %s" % tarbfile
                elif chkptfilefound:
                    print "# Checkpoint file for job found @ %s" % chkptfile
                else:
                    print "ERROR! Neither job tarball (%s) nor checkpoint file (%s) found. Huh?" % (tarbfile, chkptfile)

                # check for base script
                basescript = os.path.join(
                    chkptdirbase, chkptsubdir, basescriptname)
                if not os.path.isfile(basescript):
                    print "Base script for job (%s) not found..." % basescript
                    return (None, None)
                else:
                    print "# Base script for job found @ %s" % basescript
                    return (basescript, arrayid)


def submitbase(base, name):

    if csub_vars_map['CSUB_SCHEDULER'] == "PBS":

        try:
            # execute qsub as sub-process, catch stdout/stderr as stdout
            arrayoption = ""
            if arrayspec:
                arrayoption = "-t %s" % arrayspec
            p = popen2.Popen4('qsub %s %s' % (arrayoption, base))
            p.tochild.close()  # no input
            ec = p.wait()  # wait for qsub
            out = p.fromchild.read()  # read output
            print out  # show jod id
        except Exception, err:
            print "Something went wrong with forking qsub: %s" % err
            sys.exit(1)

        if ec > 0:
            print "Submission failed: exitcode %s, output %s" % (ec, out)
            sys.exit(1)

        print "Job with name %s succesfully submitted" % (name)

    else:
        print "ERROR! (in submitbase) Don't know how to handle %s as a job scheduler, sorry."
        sys.exit(1)


# prepare checkpoint directory tree, prestage/poststrage scripts, prologue/epilogue, job script,
def runall(scriptname, parent_dir, script, job_time, chkpt_time, prestage, poststage, shared, queue, mimic_pro_epi, cleanup_after_restart, vmem):
    global EPILOGUE, BASE, PRESTAGELOCAL, POSTSTAGELOCAL

    # make the directory

    # make sure csub_vars_map['CSUB_SCRATCH'] environment variable is there
    if csub_vars_map['CSUB_SCRATCH'] not in os.environ:
        print "%s is mandatory" % csub_vars_map['CSUB_SCRATCH']
        sys.exit(1)

    # naming convention in base and epilogue
    chkptdirbase = os.path.join(chkptdirbasebase, scriptname)
    chkptdir = os.path.join(chkptdirbase, chkptsubdir)
    if os.path.isdir(chkptdir):
        print "Chkpt dir %s already exists." % chkptdir
        sys.exit(1)

    # make the checkpoint directory
    try:
        os.makedirs(chkptdir)
    except Exception, err:
        print "Creating chkptdir %s failed: %s" % (chkptdir, err)
        sys.exit(1)

    # make the scripts
    if prestage:
        prestagefile = "%s/prestage" % (chkptdir)
        if prestage == 'local':
            prestagetxt = PRESTAGELOCAL % {'srcdir': parent_dir}

        try:
            file(prestagefile, 'w').write(prestagetxt)
            os.chmod(prestagefile, 0755)
        except Exception, err:
            print "Can't create prestage file %s:%s" % (prestagefile, err)
            sys.exit(1)

    if poststage:
        poststagefile = "%s/poststage" % (chkptdir)
        if poststage == 'local':
            localmap = {'destdir': parent_dir}
            localmap.update(csub_vars_map)
            poststagetxt = POSTSTAGELOCAL % localmap

        try:
            file(poststagefile, 'w').write(poststagetxt)
            os.chmod(poststagefile, 0755)
        except Exception, err:
            print "Can't create poststage file %s:%s" % (poststagefile, err)
            sys.exit(1)

    # the jobscript has file scriptname.sh
    # create job script
    jobscript = "%s/%s.sh" % (chkptdirbase, scriptname)
    try:
        file(jobscript, 'w').write(script)
        os.chmod(jobscript, 0755)
    except Exception, err:
        print "Can't create jobscript file %s:%s" % (jobscript, err)
        sys.exit(1)

    # prepare prologue and epilogue scripts
    epilogue_script = ""
    prologue_script = ""
    if (not shared):
        # epilogue/prologue goes to checkpoint (prologue needs symlink to epilogue)
        epilogue_script = "%s/epilogue" % chkptdirbase
        prologue_script = "%s/prologue" % chkptdirbase
        try:
            epiloguetxt = EPILOGUE % csub_vars_map
            file(epilogue_script, 'w').write(epiloguetxt)
            os.chmod(epilogue_script, 0755)
        except Exception, err:
            print "Can't create epilogue file %s:%s" % (epilogue_script, err)
            sys.exit(1)

        try:
            os.symlink(epilogue_script, prologue_script)
        except Exception, err:
            print "Can't create prologue link %s from epilogue file %s:%s" % (prologue_script, epilogue_script, err)
            sys.exit(1)

    user_chkpt_script = """#!/bin/bash
echo "Checkpointing job at request of user (time: `date`)"
# check for file containing PID of master
if [ ! -f $CSUB_MASTER_PID_FILE ]
then
   echo "ERROR! File containing job ID not available (\"$CSUB_MASTER_PID_FILE\")"
   exit 12345
else
   pid=`cat $CSUB_MASTER_PID_FILE`
fi

# touch file to acknowledge checkpoint by user
touch $CSUB_KILL_ACK_FILE
if [ $? -ne 0 ]
then
    echo "ERROR! Failed to create acknowledgement file: $CSUB_KILL_ACK_FILE ."
    rm -f $CSUB_KILL_ACK_FILE
    exit 12345
fi

# create checkpoint and kill master and its children (which includes this script)
cr_checkpoint --kill $pid -f $CSUB_CHECKPOINT_FILE
exit_code=$?
if [ $exit_code -ne 0 ]
then
    echo "ERROR! Checkpointing master (pid: `cat $CSUB_MASTER_PID_FILE`) failed (exit code: $exit_code)."
    ls -l $CSUB_CHECKPOINT_FILE
    rm -f $CSUB_KILL_ACK_FILE
    exit 12345
fi
    """

    user_chkpt_script_file = "user_chkpt_script.sh"
    try:
        user_chkpt_script_path = os.path.join(
            chkptdirbase, chkptsubdir, user_chkpt_script_file)
        file(user_chkpt_script_path, 'w').write(user_chkpt_script)
        os.chmod(user_chkpt_script_path, 0755)
    except Exception, err:
        print "Can't create user checkpointing script %s:%s" % (user_chkpt_script, err)
        sys.exit(1)

    # either mimic scheduler pro/epilogue script functionality or not
    # mimic should be done as a workaround for http://www.clusterresources.com/bugzilla/show_bug.cgi?id=42
    epilogue_header_spec = ""
    prologue_header_spec = ""
    # hack: comment out pro/epi arguments
    # and use echo to ensure exit code check in base passes
    prologue_str = "echo #"
    epilogue_str = "echo #"
    if (not shared):
        if mimic_pro_epi:
            # mimic pro/epilogue scripts by calling them from base
            prologue_str = prologue_script
            epilogue_str = epilogue_script
        else:
            # use scheduler pro/epilogue functionality, don't mimic
            epilogue_header_spec = gen_pro_epi_spec("epilogue", epilogue_script)
            prologue_header_spec = gen_pro_epi_spec("prologue", prologue_script)

    localmap = {'prologue': prologue_str,
                'epilogue': epilogue_str,
                'job_time': job_time,
                'cleanup_after_restart': cleanup_after_restart,
                'cleanup_chkpt': cleanup_chkpt,
                'chkptsubdir': chkptsubdir,
                'chkpt_save_opt': chkpt_save_opt,
                'user_chkpt_script_file': user_chkpt_script_file
                }
    localmap.update(csub_vars_map)
    base_script = BASE % localmap

    # construct total wall time string
    wall_time = job_time + chkpt_time

    # create base script by composing header and actual script
    base = "%s/%s" % (chkptdir, basescriptname)

    baseheader = gen_base_header({'wall_time': wall_time,
                                  'epilogue_header_spec': epilogue_header_spec,
                                  'prologue_header_spec': prologue_header_spec,
                                  'name': scriptname,
                                  'chkptdirbase': chkptdirbase,
                                  'queue': queue,
                                  'vmem': vmem,
                                  }, script)

    try:
        file(base, 'w').write(baseheader + base_script)
    except Exception, err:
        print "Can't create base jobscript %s:%s" % (base, err)
        sys.exit(1)

    if not shared:
        # make chkpoint tarball
        # options must match pack/unpack from epilogue
        tb = os.path.join(chkptdir, tarbfilename)
        cmd = "tar -c -p -C %s -f %s . && touch %s.ok" % (chkptdirbase, tb, tb)
        try:
            p = popen2.Popen4(cmd)  # execute tar in sub-process, catch both stdout/stderr as stdout
            p.tochild.close()  # no input to pass
            ec = p.wait()  # wait for process, catch return value
            out = p.fromchild.read()  # read output of tar command
        except Exception, err:
            print "Something went wrong with forking tar (%s): %s" % (cmd, err)
            sys.exit(1)
        if ec > 0:
            print "Tar failed: exitcode %s, output %s, cmd %s" % (ec, out, cmd)
            sys.exit(1)

    # submit 1 job
    submitbase(base, scriptname)


# try to parse time string and compute in seconds
def parsetime(time_str):
    regtime = re.compile(
        "(?P<hours>^\d+):(?P<mins>\d+):(?P<secs>\d+)$").search(time_str)
    if regtime:
        hours = int(regtime.group("hours"))
        mins = int(regtime.group("mins"))
        secs = int(regtime.group("secs"))
        return hours * 3600 + mins * 60 + secs
    else:
        return None


if __name__ == '__main__':
    import getopt

    allopts = ["help", "pre", "post", "shared", "job_time=", "chkpt_time=",
               "cleanup_after_restart", "no_cleanup_chkpt", "resume=", "chkpt_save_opt=",
               "term_kill_mode", "vmem="]
    try:
        opts, args = getopt.getopt(sys.argv[1:], "hs:q:t:", allopts)
    except getopt.GetoptError, err:
        print "\n" + str(err)
        usage()
        sys.exit(2)

    script = None
    prestage = None
    poststage = None
    shared = False
    queue = None
    # variable to control hack which mimics prologue/epilogue functionality
    # this should be removed when the prologue/epilogue problems caused by root squash are fixed in Torgue
    mimic_pro_epi = True
    job_time_spec = False
    job_time = 10 * 60 * 60  # default: 10 hours
    chkpt_time_spec = False
    chkpt_time = 15 * 60  # default: 15 minutes
    arrayspec = None
    cleanup_after_restart = False
    cleanup_chkpt = True
    resume_job_name = None
    chkpt_save_opt = "exe"
    vmem = None

    # read command line options specified
    for key, value in opts:
        if key in ["-h", "--help"]:
            usage()
        if key in ["-s"]:
            script_filename = value
            try:
                script = open(script_filename).read()
            except Exception, err:
                print "Can't read jobscript %s:%s" % (script_filename, err)
                sys.exit(1)
        if key in ["-q"]:
            queue = value
        if key in ["-t"]:
            arrayspec = value
        if key in ["--job_time"]:
            job_time_str = value
            job_time = parsetime(job_time_str)
            if not job_time:
                print "Failed to parse specified job time (%s)." % job_time_str
                print "Please specify job time using <hours>:<minutes>:<seconds>, e.g. '3:12:47'"
                sys.exit(1)
            job_time_spec = True
        if key in ["--chkpt_time"]:
            chkpt_time_str = value
            chkpt_time = parsetime(chkpt_time_str)
            if not chkpt_time:
                print "Failed to parse specified job time (%s)." % chkpt_time_str
                print "Please specify checkpoint time using <hours>:<minutes>:<seconds>, e.g. '3:12:47'"
                sys.exit(1)
            chkpt_time_spec = True
        if key in ['--pre']:
            prestage = 'local'
        if key in ['--post']:
            poststage = 'local'
        if key in ['--shared']:
            shared = True
        if key in ['--no_mimic_pro_epi']:
            mimic_pro_epi = False
        if key in ['--cleanup_after_restart']:
            cleanup_after_restart = True
        if key in ['--no_cleanup_chkpt']:
            cleanup_chkpt = False
        if key in ['--resume']:
            resume_job_name = value
        if key in ['--chkpt_save_opt']:
            known_chkpt_save_opts = ['all', 'exe', 'none']
            if value not in known_chkpt_save_opts:
                print "Invalid value for chkpt_save_opt specified: %s." % value
                print "Please use one of the following: %s" % ','.join(known_chkpt_save_opts)
                sys.exit(1)
            else:
                chkpt_save_opt = value
        if key in ['--term_kill_mode']:
            csub_vars_map.update({'CSUB_KILL_MODE': 'term'})
        if key in ['--vmem']:
            vmem = value

    if not script and not resume_job_name:
        print """ERROR! No jobscript read or job to resume specified.
Please use -s or --script to specify the job script, or
use --resume=>job_name> to resume a job from the latest checkpoint.
(use -h or --help for help)"""
        sys.exit(1)

    if resume_job_name:

        if script or queue or arrayspec or prestage or poststage:
            txt = """ERROR! Found extra options when resuming from checkpoint! (see -h or --help)
This is useless, because the original job script is part of the checkpoint, and this script will be resubmitted.
If you want to vary job parameters, please see --vmem, --job_time and/or --chkpt_time."""
            print txt
            sys.exit(1)

        # try and resume job with specified name
        (base, arrayid) = checkResume(resume_job_name)

        if base:
            # make sure it also works correctly for array jobs
            if arrayid:
                arrayspec = arrayid

            try:
                f = open(base, "r")
                basetxt = f.read()
                f.close()
            except Exception, err:
                print "Failed to read base script %s: %s" % (base, err)

            # change job time and/or chkpt_time before resubmitting
            if job_time_spec or chkpt_time_spec or vmem:
                walltime_script = get_wall_time(basetxt)

                job_time_regexp = re.compile(
                    "^(chksltot)=(?P<job_time>[0-9]+)\s*(\S*)$", re.MULTILINE)
                job_time_script = int(
                    job_time_regexp.search(basetxt).group('job_time'))

                if job_time_spec:
                    new_job_time = job_time
                else:
                    new_job_time = job_time_script

                if chkpt_time_spec:
                    new_chkpt_time = chkpt_time
                else:
                    new_chkpt_time = walltime_script - job_time_script

                wall_time_str = gen_wall_time_str(
                    new_job_time + new_chkpt_time)

                basetxt = job_time_regexp.sub(
                    r"\1=%d \3\n" % new_job_time, basetxt)
                basetxt = replace_walltime_str(basetxt, wall_time_str)

                if vmem:
                    basetxt = replace_vmem(basetxt, vmem)

                try:
                    f = open(base, "w")
                    f.write(basetxt)
                    f.close()
                except Exception, err:
                    print "Failed to backup/rewrite base script %s when adjusting job_time/chkpt_time: %s" % (base, err)
                    sys.exit(1)

            outputfiles = re.compile("^\s*#PBS\s+-o\s+(?P<chkptdirbase>\S+)/(?P<name>[^/]+).base.out\s*$", re.MULTILINE).search(basetxt).groupdict()
            tomove = []

            if arrayid:
                outputfiles["arrayid"] = arrayid
                tomove.append("%(chkptdirbase)s-%(arrayid)s/%(name)s-%(arrayid)s.out" % outputfiles)
                tomove.append("%(chkptdirbase)s-%(arrayid)s/%(name)s-%(arrayid)s.err" % outputfiles)
            else:
                tomove.append("%(chkptdirbase)s/%(name)s.out" % outputfiles)
                tomove.append("%(chkptdirbase)s/%(name)s.err" % outputfiles)

            for filename in tomove:
                try:
                    print "Taking backup of output file %s" % filename
                    shutil.copy2(filename, "%s.prev" % filename)
                except OSError, err:
                    print "Failed to rename the log output of the previous run: %s" % filename
                    sys.exit(1)

            submitbase(base, resume_job_name)
            print "Job %s succesfully resumed." % resume_job_name
        else:
            print "Resuming of job %s failed. Sorry." % resume_job_name
            sys.exit(1)
    else:
        # start new job
        # generate unique script name
        unique_script_name = uniquescriptname(script_filename, script)

        # parent directory of script (for copying local results in prestage/poststage)
        parent_dir = os.path.dirname(os.path.abspath(script_filename))

        runall(unique_script_name, parent_dir, script, job_time, chkpt_time, prestage, poststage, shared, queue, mimic_pro_epi, cleanup_after_restart, vmem)
