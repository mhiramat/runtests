#!/bin/sh

# runtests.sh - A shell script to run test cases
#
# Derived from testing/selftest/ftracetest
# Copyright (C) Hitachi Ltd., 2014, 2015
#  Written by Masami Hiramatsu <masami.hiramatsu.pt@hitachi.com>
#
# Released under the terms of the GPL v2.

SCRIPTNAME=$0

usage() { # errno [message]
[ "$2" ] && echo $2
echo "Usage: $SCRIPTNAME [options] [testcase(s)] [testcase-directory(s)]"
echo " Options:"
echo "         -h|--help  Show help message"
echo "         -k|--keep  Keep passed test logs"
echo "         -v|--verbose Show all stdout messages in testcases"
echo "         -d|--debug Debug mode (trace all shell commands)"
exit $1
}

errexit() { # message
  echo "Error: $1" 1>&2
  exit 1
}

# Ensuring user privilege
if [ `id -u` -ne 0 ]; then
  errexit "this must be run by root user"
fi

# Utilities
absdir() { # file_path
  (cd `dirname $1`; pwd)
}

abspath() {
  echo `absdir $1`/`basename $1`
}

find_testcases() { #directory
  echo `find $1 -name \*.tc | sort`
}

parse_opts() { # opts
  local OPT_TEST_CASES=
  local OPT_TEST_DIR=

  while [ "$1" ]; do
    case "$1" in
    --help|-h)
      usage 0
    ;;
    --keep|-k)
      KEEP_LOG=1
    ;;
    --verbose|-v)
      VERBOSE=1
    ;;
    --debug|-d)
      DEBUG=1
    ;;
    *.tc)
      if [ -f "$1" ]; then
        OPT_TEST_CASES="$OPT_TEST_CASES `abspath $1`"
      else
        usage 1 "$1 is not a testcase"
      fi
      ;;
    *)
      if [ -d "$1" ]; then
        OPT_TEST_DIR=`abspath $1`
        OPT_TEST_CASES="$OPT_TEST_CASES `find_testcases $OPT_TEST_DIR`"
      else
        usage 1 "Invalid option ($1)"
      fi
    ;;
    esac
    shift 1
  done
  if [ "$OPT_TEST_CASES" ]; then
    TEST_CASES=$OPT_TEST_CASES
  fi
}

# Parameters
CONFIG=./runtests.conf
TOP_DIR=`absdir $0`
TEST_DIR=$TOP_DIR/test.d
TEST_CASES=`find_testcases $TEST_DIR`
LOG_DIR=$TOP_DIR/logs/`date +%Y%m%d-%H%M%S`/
KEEP_LOG=0
DEBUG=0
VERBOSE=0
# Parse command-line options
parse_opts $*

[ $DEBUG -ne 0 ] && set -x

# Config parameters
# setup this here since PERF_DIR can be referred in config file
[ -z "$PERF_DIR" ] && PERF_DIR=/usr/bin

[ -f "$CONFIG" ] && . $CONFIG

[ -z "$PERF" ] && PERF=$PERF_DIR/perf

# Preparing logs
LOG_FILE=$LOG_DIR/${SCRIPTNAME}.log
mkdir -p $LOG_DIR || errexit "Failed to make a log directory: $LOG_DIR"
date > $LOG_FILE
prlog() { # messages
  echo "$@" | tee -a $LOG_FILE
}
catlog() { #file
  cat $1 | tee -a $LOG_FILE
}
prlog "=== Run tests ==="

# Testcase management
# Test result codes - Dejagnu extended code
PASS=0 # The test succeeded.
FAIL=1 # The test failed, but was expected to succeed.
UNRESOLVED=2  # The test produced indeterminate results. (e.g. interrupted)
UNTESTED=3    # The test was not run, currently just a placeholder.
UNSUPPORTED=4 # The test failed because of lack of feature.
XFAIL=5        # The test failed, and was expected to fail.

# Accumulations
PASSED_CASES=
FAILED_CASES=
UNRESOLVED_CASES=
UNTESTED_CASES=
UNSUPPORTED_CASES=
XFAILED_CASES=
UNDEFINED_CASES=
TOTAL_RESULT=0

CASENO=0
testcase() { # testfile
  CASENO=$((CASENO+1))
  desc=`grep "^#[ \t]*description:" $1 | cut -f2 -d:`
  prlog -n "[$CASENO]$desc"
}

eval_result() { # sigval
  case $1 in
    $PASS)
      prlog "  [PASS]"
      PASSED_CASES="$PASSED_CASES $CASENO"
      return 0
    ;;
    $FAIL)
      prlog "  [FAIL]"
      FAILED_CASES="$FAILED_CASES $CASENO"
      return 1 # this is a bug.
    ;;
    $UNRESOLVED)
      prlog "  [UNRESOLVED]"
      UNRESOLVED_CASES="$UNRESOLVED_CASES $CASENO"
      return 1 # this is a kind of bug.. something happened.
    ;;
    $UNTESTED)
      prlog "  [UNTESTED]"
      UNTESTED_CASES="$UNTESTED_CASES $CASENO"
      return 0
    ;;
    $UNSUPPORTED)
      prlog "  [UNSUPPORTED]"
      UNSUPPORTED_CASES="$UNSUPPORTED_CASES $CASENO"
      return 1 # this is not a bug, but the result should be reported.
    ;;
    $XFAIL)
      prlog "  [XFAIL]"
      XFAILED_CASES="$XFAILED_CASES $CASENO"
      return 0
    ;;
    *)
      prlog "  [UNDEFINED]"
      UNDEFINED_CASES="$UNDEFINED_CASES $CASENO"
      return 1 # this must be a test bug
    ;;
  esac
}

# Signal handling for result codes
SIG_RESULT=
SIG_BASE=36    # Use realtime signals
SIG_PID=$$

SIG_FAIL=$((SIG_BASE + FAIL))
trap 'SIG_RESULT=$FAIL' $SIG_FAIL

SIG_UNRESOLVED=$((SIG_BASE + UNRESOLVED))
exit_unresolved () {
  kill -s $SIG_UNRESOLVED $SIG_PID
  exit 0
}
trap 'SIG_RESULT=$UNRESOLVED' $SIG_UNRESOLVED

SIG_UNTESTED=$((SIG_BASE + UNTESTED))
exit_untested () {
  kill -s $SIG_UNTESTED $SIG_PID
  exit 0
}
trap 'SIG_RESULT=$UNTESTED' $SIG_UNTESTED

SIG_UNSUPPORTED=$((SIG_BASE + UNSUPPORTED))
exit_unsupported () {
  kill -s $SIG_UNSUPPORTED $SIG_PID
  exit 0
}
trap 'SIG_RESULT=$UNSUPPORTED' $SIG_UNSUPPORTED

SIG_XFAIL=$((SIG_BASE + XFAIL))
exit_xfail () {
  kill -s $SIG_XFAIL $SIG_PID
  exit 0
}
trap 'SIG_RESULT=$XFAIL' $SIG_XFAIL

__run_test() { # testfile
  # setup PID and PPID, $$ is not updated.
  (cd $TRACING_DIR; read PID _ < /proc/self/stat ; set -e; set -x; . $1)
  [ $? -ne 0 ] && kill -s $SIG_FAIL $SIG_PID
}

# Run one test case
run_test() { # testfile
  local testname=`basename $1`
  local testlog=`mktemp $LOG_DIR/${testname}-log.XXXXXX`
  testcase $1
  echo "execute: "$1 > $testlog
  SIG_RESULT=0
  if [ $VERBOSE -ne 0 ]; then
    __run_test $1 2>> $testlog | tee -a $testlog
  else
    __run_test $1 >> $testlog 2>&1
  fi
  eval_result $SIG_RESULT
  if [ $? -eq 0 ]; then
    # Remove test log if the test was done as it was expected.
    [ $KEEP_LOG -eq 0 ] && rm $testlog
  else
    catlog $testlog
    TOTAL_RESULT=1
  fi
}

# load in the helper functions
[ -f $TEST_DIR/functions ] && . $TEST_DIR/functions

# Main loop
for t in $TEST_CASES; do
  run_test $t
done

prlog ""
prlog "# of passed: " `echo $PASSED_CASES | wc -w`
prlog "# of failed: " `echo $FAILED_CASES | wc -w`
prlog "# of unresolved: " `echo $UNRESOLVED_CASES | wc -w`
prlog "# of untested: " `echo $UNTESTED_CASES | wc -w`
prlog "# of unsupported: " `echo $UNSUPPORTED_CASES | wc -w`
prlog "# of xfailed: " `echo $XFAILED_CASES | wc -w`
prlog "# of undefined(test bug): " `echo $UNDEFINED_CASES | wc -w`

# if no error, return 0
exit $TOTAL_RESULT
