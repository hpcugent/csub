This repository contains code to generate a csub script, this is wrapper script around qsub and blcr,
which will take a command, and automatically checkpoint it. If a job is about to run out of it's wall
time, the script will use blcr to checkpoint all it's information, and resubmit it, until the command
is done. This currently does not work very well for multi threaded jobs, and not at all for mpi jobs.
We could switch to dmtcp and test if this works as advertised, see https://github.com/hpcugent/csub/issues/2


Generate a csub for your environment
====================================

Generate a wrapper script around blcr and the job submission system to auto checkpoint certain jobs.

Edit the `base.sh` and `epologue.sh` files so they are to your liking.
Edit the constant variables at the top of the `csub.py` file to match your environment.
run `python makecsub.py`

This will generate a csub executable script which can be used to submit jobs that will be automatically
checkpointed using bclr (bclr should be installed on the worker nodes, it is not required on the
job submission nodes).

Using csub
==========
One important caveat is that the job script (or the applications run in the script) should not create
it's own local temporary directories.

Also note that adding PBS directives (#PBS) in the job script is useless, as they will be ignored by
csub. Controlling job parameters should be done via the csub command line.

Help on the various command line parameters supported by csub can be obtained using `csub -h`.

Some notable options:
 * `--pre` and `--post`: The `--pre` and `--post` parameters steer whether local files are copied
   or not. The job submitted using csub is (by default) run on the local storage provided by a 
   particular compute node. Thus, no changes will be made to the files on the shared storage 
   (e.g. `$VSC_SCRATCH`). If the job script needs (local) access to the files of the directory 
   where csub is executed, `--pre` should be specified. This will copy all the files in the 
   job script directory to the location where the job script will execute. If the output of the
   job that was run, or additional output files created by the job in it's working directory are
   required, `--post` should be used. This will copy the entire job working directory to the
   location where csub was executed, in a directory named `result.<jobname>`. An alternative is
   to copy the interesting files to the shared storage at the end of the job script.
 * `--shared`: If the job needs to be run on the shared storage and not on the local storage 
   of the worker node, `--shared` should be specified. In this case, the job will be run in
   a subdirectory of `$VSC_SCRATCH/chkpt`. This will also disable the execution of the 
   prologue and epilogue scripts, which prepare the job directory on the local storage.
 * `--job_time` and `--chkpt_time`: To specify the requested wall time per subjob, use 
   the `--job-time` parameter. The default settings is 10 hours per subjob. Lowering this will
   result in more frequent checkpointing, and thus more subjobs. To specify the time that is 
   reserved for checkpointing the job, use `--chkpt_time`. By default, this is set to 15 minutes
   which should be enough for most applications/jobs. Don't change this unless you really need
   to. The total requested wall time per subjob is the sum of both `job_time` and `chkpt_time`.
   This should be taken into account when submitting to a specific job queue 
   (e.g., queues which only support jobs of up to 1 hour).
 * `--no_mimic_pro_epi`: The option `--no_mimic_pro_epi` disables the workaround currently
   implemented for a permissions problem when using actual Torque prologue/epilogue scripts.
   Don't use this option unless you really know what you're doing!


Array jobs
----------

csub has support for checkpointing array jobs.  Just specify `-t <spec>` on the csub 
command line (see qsub for details).


MPI support
------------
The BLCR checkpointing mechanism behind csub has support for checkpointing MPI applications.
However, checkpointing MPI applications is pretty much untested up until now. If you would like
to use csub with your MPI applications, you should help us replace blcr with dmtcp.
(see http://mug.mvapich.cse.ohio-state.edu/static/media/mug/presentations/2014/cooperman.pdf)


Notes
------

If you would like to time how long the complete job executes, just prepend the main command
in your job script with time, e.g.: time <command>. The real time will not make sense as it
will also include the time passes between two checkpointed subjobs. However, the user time
should give a good indication of the actual time it took to run your command, even if 
multiple checkpoints were performed.
