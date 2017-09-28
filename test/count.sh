#!/bin/bash
python -c "
import datetime, sys, time
for i in range(150):
  print i, datetime.datetime.now()
  sys.stdout.flush()
  time.sleep(1)
"
