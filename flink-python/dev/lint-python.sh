#!/usr/bin/env bash
################################################################################
#  Licensed to the Apache Software Foundation (ASF) under one
#  or more contributor license agreements.  See the NOTICE file
#  distributed with this work for additional information
#  regarding copyright ownership.  The ASF licenses this file
#  to you under the Apache License, Version 2.0 (the
#  "License"); you may not use this file except in compliance
#  with the License.  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

# lint-python.sh
# This script will prepare a virtual environment for many kinds of checks, such as tox check, flake8 check.
#
# You can refer to the README.MD in ${flink-python} to learn how easy to run the script.
#

# Download some software, such as the uv installer
function download() {
    local DOWNLOAD_STATUS=
    if hash "wget" 2>/dev/null; then
        # because of the difference of all versions of wget, so we turn of the option --show-progress
        wget "$1" -O "$2" -q -T20 -t3
        DOWNLOAD_STATUS="$?"
    else
        curl "$1" -o "$2" --progress-bar --connect-timeout 20 --retry 3
        DOWNLOAD_STATUS="$?"
    fi
    if [ $DOWNLOAD_STATUS -ne 0 ]; then
        echo "Download failed.You can try again"
        exit $DOWNLOAD_STATUS
    fi
}

# Printing infos both in log and console
function print_function() {
    local STAGE_LENGTH=48
    local left_edge_len=
    local right_edge_len=
    local str
    case "$1" in
        "STAGE")
            left_edge_len=$(((STAGE_LENGTH-${#2})/2))
            right_edge_len=$((STAGE_LENGTH-${#2}-left_edge_len))
            str="$(seq -s "=" $left_edge_len | tr -d "[:digit:]")""$2""$(seq -s "=" $right_edge_len | tr -d "[:digit:]")"
            ;;
        "STEP")
            str="$2"
            ;;
        *)
            str="seq -s "=" $STAGE_LENGTH | tr -d "[:digit:]""
            ;;
    esac
    echo $str | tee -a $LOG_FILE
}

function regexp_match() {
    if echo $1 | grep -e $2 &>/dev/null; then
        echo true
    else
        echo false
    fi
}

# decide whether a array contains a specified element.
function contains_element() {
    arr=($1)
    if echo "${arr[@]}" | grep -w "$2" &>/dev/null; then
        echo true
    else
        echo false
    fi
}

# Checkpoint the stage:step for convenient to re-exec the script with
# skipping those success steps.
# The format is "${Stage}:${Step}". e.g. Install:4
function checkpoint_stage() {
    if [ ! -d `dirname $STAGE_FILE` ]; then
        mkdir -p `dirname $STAGE_FILE`
    fi
    echo "$1:$2">"$STAGE_FILE"
}

# Restore the stage:step
function restore_stage() {
    if [ -f "$STAGE_FILE" ]; then
        local lines=$(awk '{print NR}' $STAGE_FILE)
        if [ $lines -eq 1 ]; then
            local first_field=$(cat $STAGE_FILE | cut -d ":" -f 1)
            local second_field=$(cat $STAGE_FILE | cut -d ":" -f 2)
            check_valid_stage $first_field $second_field
            if [ $? -eq 0 ]; then
                STAGE=$first_field
                STEP=$second_field
                return
            fi
        fi
    fi
    STAGE="install"
    STEP=0
}

# Decide whether the stage:step is valid.
function check_valid_stage() {
    case $1 in
        "install")
            if [ $2 -le $STAGE_INSTALL_STEPS ] && [ $2 -ge 0 ]; then
                return 0
            fi
            ;;
        *)
            ;;
    esac
    return 1
}

function parse_component_args() {
    local REAL_COMPONENTS=()
    for component in ${INSTALLATION_COMPONENTS[@]}; do
        # because all other components depends on uv, the install of uv is
        # required component.
        if [[ "$component" == "basic" ]] || [[ "$component" == "uv" ]]; then
            continue
        fi
        if [[ "$component" == "all" ]]; then
            component="environment"
        fi
        if [[ `contains_element "${SUPPORTED_INSTALLATION_COMPONENTS[*]}" "${component}"` = true ]]; then
            REAL_COMPONENTS+=(${component})
        else
            echo "unknown install component ${component}, currently we only support installing basic,py_env,tox,flake8,sphinx,mypy,all."
            exit 1
        fi
    done
    if [[ `contains_element "${REAL_COMPONENTS[*]}" "environment"` = false ]]; then
        SUPPORTED_INSTALLATION_COMPONENTS=(${REAL_COMPONENTS[@]})
    fi
}

# For convenient to index something binded to OS.
function get_os_index() {
    local sys_os=$(uname -s)
    echo "Detected OS: ${sys_os}"
    if [ ${sys_os} == "Darwin" ]; then
        return 0
    elif [[ ${sys_os} == "Linux" ]]; then
        return 1
    else
        echo "Unsupported OS: ${sys_os}"
        exit 1
    fi
}

function install_brew() {
    hash "brew" 2>/dev/null
    if [ $? -ne 0 ]; then
        print_function "STEP" "install brew..."
        $((/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)") 2>&1 >/dev/null)
        if [ $? -ne 0 ]; then
            echo "Failed to install brew"
            exit 1
        fi
        print_function "STEP" "install brew... [SUCCESS]"
    fi
}

# We are using uv as our package management and python version management tool.
# The downstream scripts use uv to install packages, like tox and flake8, as well
# as manage different Python virtual environments that have different version of
# Python installed.

function install_uv() {
    UV_INSTALL_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-installer.sh"
    if [ ! -f "$UV_INSTALL" ]; then
        print_function "STEP" "download uv from ${UV_INSTALL_URL}..."
        download $UV_INSTALL_URL $UV_INSTALL_SH
        chmod +x $UV_INSTALL_SH
        if [ $? -ne 0 ]; then
            echo "Please manually chmod +x $UV_INSTALL_SH"
            exit 1
        fi
        if [ -d "$CURRENT_DIR/.uv" ]; then
            rm -rf "$CURRENT_DIR/.uv"
            if [ $? -ne 0 ]; then
                echo "Please manually rm -rf $CURRENT_DIR/.uv-bin directory.\
                Then retry to exec the script."
                exit 1
            fi
        fi

        UV_UNMANAGED_INSTALL="$CURRENT_DIR/download" $UV_INSTALL_SH
        print_function "STEP" "download uv... [SUCCESS]"
    fi

    if [ ! -d "$CURRENT_DIR/.uv/venv" ]; then
        print_function "STEP" "setup uv virtualenv"
        # Create a Python 3.12 virtual environment as the base environment.
        $CURRENT_DIR/download/uv venv "$CURRENT_DIR/.uv" --seed --python 3.12
        print_function "STEP" "setup uv virtualenv... [SUCCESS]"
        # orjson depend on pip >= 20.3
        print_function "STEP" "upgrade pip..."
        $CURRENT_DIR/.uv/bin/pip install --upgrade pip setuptools 2>&1 >/dev/null
        print_function "STEP" "upgrade pip... [SUCCESS]"
        # move uv binaries into virtual env
        mv "$CURRENT_DIR/download/uv" "$CURRENT_DIR/.uv/bin/"
    fi
}

# Create different Python virtual environments for different Python versions
function install_py_env() {
    py_env=("3.9" "3.10" "3.11" "3.12")
    for ((i=0;i<${#py_env[@]};i++)) do
        if [ -d "$CURRENT_DIR/.uv/envs/${py_env[i]}" ]; then
            rm -rf "$CURRENT_DIR/.uv/envs/${py_env[i]}"
            if [ $? -ne 0 ]; then
                echo "rm -rf $CURRENT_DIR/.uv/envs/${py_env[i]} failed, please \
                rm -rf $CURRENT_DIR/.uv/envs/${py_env[i]} manually.\
                Then retry to exec the script."
                exit 1
            fi
        fi
        print_function "STEP" "installing python${py_env[i]}..."
        max_retry_times=3
        retry_times=0
        install_command="$UV_PATH venv $CURRENT_DIR/.uv/envs/${py_env[i]} -q --python=${py_env[i]} --seed"
        ${install_command} 2>&1 >/dev/null
        status=$?
        while [[ ${status} -ne 0 ]] && [[ ${retry_times} -lt ${max_retry_times} ]]; do
            retry_times=$((retry_times+1))
            # sleep 3 seconds and then reinstall.
            sleep 3
            echo "uv venv ${py_env[i]} retrying ${retry_times}/${max_retry_times}"
            ${install_command} 2>&1 >/dev/null
            status=$?
        done
        if [[ ${status} -ne 0 ]]; then
            echo "uv venv ${py_env[i]} failed after retrying ${max_retry_times} times.\
            You can retry to execute the script again."
            exit 1
        fi

        $CURRENT_DIR/.uv/envs/${py_env[i]}/bin/pip install -q uv==${UV_VERSION}
        print_function "STEP" "install python${py_env[i]}... [SUCCESS]"
    done
}

# Install tox.
# In some situations,you need to run the script with "sudo". e.g. sudo ./lint-python.sh
function install_tox() {
    source $ENV_HOME/bin/activate
    if [ -f "$TOX_PATH" ]; then
        $UV_PATH pip uninstall tox -q 2>&1 >/dev/null
        if [ $? -ne 0 ]; then
            echo "uv pip uninstall tox failed \
            please try to exec the script again.\
            if failed many times, you can try to exec in the form of sudo ./lint-python.sh -f"
            exit 1
        fi
    fi

    $CURRENT_DIR/install_command.sh -q --group "${PYPROJECT_PATH}:tox" 2>&1 >/dev/null
    if [ $? -ne 0 ]; then
        echo "uv pip install tox failed \
        please try to exec the script again.\
        if failed many times, you can try to exec in the form of sudo ./lint-python.sh -f"
        exit 1
    fi
    deactivate
}

# Install flake8.
# In some situations,you need to run the script with "sudo". e.g. sudo ./lint-python.sh
function install_flake8() {
    source $UV_HOME/bin/activate
    if [ -f "$FLAKE8_PATH" ]; then
        $UV_PATH pip uninstall flake8 -q 2>&1 >/dev/null
        if [ $? -ne 0 ]; then
            echo "uv pip uninstall flake8 failed \
            please try to exec the script again.\
            if failed many times, you can try to exec in the form of sudo ./lint-python.sh -f"
            exit 1
        fi
    fi

    $CURRENT_DIR/install_command.sh -q --group "${PYPROJECT_PATH}:flake8" 2>&1 >/dev/null
    if [ $? -ne 0 ]; then
        echo "uv pip install flake8 failed \
        please try to exec the script again.\
        if failed many times, you can try to exec in the form of sudo ./lint-python.sh -f"
        exit 1
    fi
    deactivate
}

# Install sphinx.
# In some situations,you need to run the script with "sudo". e.g. sudo ./lint-python.sh
function install_sphinx() {
    source $UV_HOME/bin/activate
    if [ -f "$SPHINX_PATH" ]; then
        $UV_PATH pip uninstall Sphinx -q 2>&1 >/dev/null
        if [ $? -ne 0 ]; then
            echo "uv pip uninstall sphinx failed \
            please try to exec the script again.\
            if failed many times, you can try to exec in the form of sudo ./lint-python.sh -f"
            exit 1
        fi
    fi

    $CURRENT_DIR/install_command.sh -q --group "${PYPROJECT_PATH}:sphinx" 2>&1 >/dev/null
    if [ $? -ne 0 ]; then
        echo "uv pip install sphinx failed \
        please try to exec the script again.\
        if failed many times, you can try to exec in the form of sudo ./lint-python.sh -f"
        exit 1
    fi
    deactivate
}


# Install mypy.
# In some situations, you need to run the script with "sudo". e.g. sudo ./lint-python.sh
function install_mypy() {
    source ${UV_HOME}/bin/activate
    if [[ -f "$MYPY_PATH" ]]; then
        ${UV_PATH} pip uninstall mypy -q 2>&1 >/dev/null
        if [[ $? -ne 0 ]]; then
            echo "uv pip uninstall mypy failed \
            please try to exec the script again.\
            if failed many times, you can try to exec in the form of sudo ./lint-python.sh -f"
            exit 1
        fi
    fi
    ${CURRENT_DIR}/install_command.sh -q --group "${PYPROJECT_PATH}:mypy" 2>&1 >/dev/null
    if [[ $? -ne 0 ]]; then
        echo "uv pip install mypy failed \
        please try to exec the script again.\
        if failed many times, you can try to exec in the form of sudo ./lint-python.sh -f"
        exit 1
    fi
    deactivate
}

function need_install_component() {
    if [[ `contains_element "${SUPPORTED_INSTALLATION_COMPONENTS[*]}" "$1"` = true ]]; then
        echo true
    else
        echo false
    fi
}


# In this function, the script will prepare all kinds of python environments and checks.
function install_environment() {

    print_function "STAGE" "installing environment"

    #get the index of the SUPPORT_OS array for convenient to install tool.
    get_os_index $sys_os
    local os_index=$?

    # step-1 install uv
    if [ $STEP -lt 1 ]; then
        print_function "STEP" "installing uv..."
        create_dir $CURRENT_DIR/download
        install_uv
        STEP=1
        checkpoint_stage $STAGE $STEP
        print_function "STEP" "install uv... [SUCCESS]"
    fi

    # step-2 install python environment which includes
    # 3.9 3.10 3.11 3.12
    if [ $STEP -lt 2 ] && [ `need_install_component "py_env"` = true ]; then
        print_function "STEP" "installing python environment..."
        install_py_env
        STEP=2
        checkpoint_stage $STAGE $STEP
        print_function "STEP" "install python environment... [SUCCESS]"
    fi

    # step-3 install tox
    if [ $STEP -lt 3 ] && [ `need_install_component "tox"` = true ]; then
        print_function "STEP" "installing tox..."
        install_tox
        STEP=3
        checkpoint_stage $STAGE $STEP
        print_function "STEP" "install tox... [SUCCESS]"
    fi

    # step-4 install  flake8
    if [ $STEP -lt 4 ] && [ `need_install_component "flake8"` = true ]; then
        print_function "STEP" "installing flake8..."
        install_flake8
        STEP=4
        checkpoint_stage $STAGE $STEP
        print_function "STEP" "install flake8... [SUCCESS]"
    fi

    # step-5 install sphinx
    if [ $STEP -lt 5 ] && [ `need_install_component "sphinx"` = true ]; then
        print_function "STEP" "installing sphinx..."
        install_sphinx
        STEP=5
        checkpoint_stage $STAGE $STEP
        print_function "STEP" "install sphinx... [SUCCESS]"
    fi

    # step-5 install mypy
    if [[ ${STEP} -lt 6 ]] && [[ `need_install_component "mypy"` = true ]]; then
        print_function "STEP" "installing mypy..."
        install_mypy
        STEP=6
        checkpoint_stage ${STAGE} ${STEP}
        print_function "STEP" "install mypy... [SUCCESS]"
    fi

    print_function "STAGE"  "install environment... [SUCCESS]"
}

# create dir if needed
function create_dir() {
    if [ ! -d $1 ]; then
        mkdir -p $1
        if [ $? -ne 0 ]; then
            echo "mkdir -p $1 failed. you can mkdir manually or exec the script with \
            the command: sudo ./lint-python.sh"
            exit 1
        fi
    fi
}

# Set created py-env in $PATH for tox's creating virtual env
function activate () {
    if [ ! -d $CURRENT_DIR/.uv/envs ]; then
        echo "For some unknown reasons, missing the directory $CURRENT_DIR/.uv/envs,\
        you should exec the script with the option: -f"
        exit 1
    fi

    for py_dir in $CURRENT_DIR/.uv/envs/*
    do
        PATH=$py_dir/bin:$PATH
    done
    export PATH 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "For some unknown reasons, the py package is not complete,\
        you should exec the script with the option: -f"
        exit 1
    fi
}

# Reset the $PATH
function deactivate() {
    # reset old environment variables
    # ! [ -z ${VAR+_} ] returns true if VAR is declared at all
    if ! [ -z "${_OLD_PATH+_}" ] ; then
        PATH="$_OLD_PATH"
        export PATH
        unset _OLD_PATH
    fi
}

# Collect checks
function collect_checks() {
    if [ ! -z "$EXCLUDE_CHECKS" ] && [ ! -z  "$INCLUDE_CHECKS" ]; then
        echo "You can't use option -s and -e simultaneously."
        exit 1
    fi
    if [ ! -z "$EXCLUDE_CHECKS" ]; then
        for (( i = 0; i < ${#EXCLUDE_CHECKS[@]}; i++)); do
            if [[ `contains_element "${SUPPORT_CHECKS[*]}" "${EXCLUDE_CHECKS[i]}_check"` = true ]]; then
                SUPPORT_CHECKS=("${SUPPORT_CHECKS[@]/${EXCLUDE_CHECKS[i]}_check}")
            else
                echo "the check ${EXCLUDE_CHECKS[i]} is invalid."
                exit 1
            fi
        done
    fi
    if [ ! -z "$INCLUDE_CHECKS" ]; then
        REAL_SUPPORT_CHECKS=()
        for (( i = 0; i < ${#INCLUDE_CHECKS[@]}; i++)); do
            if [[ `contains_element "${SUPPORT_CHECKS[*]}" "${INCLUDE_CHECKS[i]}_check"` = true ]]; then
                REAL_SUPPORT_CHECKS+=("${INCLUDE_CHECKS[i]}_check")
            else
                echo "the check ${INCLUDE_CHECKS[i]} is invalid."
                exit 1
            fi
        done
        SUPPORT_CHECKS=(${REAL_SUPPORT_CHECKS[@]})
    fi
}

# If the check stage is needed
function include_stage() {
    if [[ `contains_element "${SUPPORT_CHECKS[*]}" "$1"` = true ]]; then
        return 0
    else
        return 1
    fi
}

# get all supported checks functions
function get_all_supported_checks() {
    _OLD_IFS=$IFS
    IFS=$'\n'
    SUPPORT_CHECKS=()
    for fun in $(declare -F); do
        if [[ `regexp_match "$fun" "_check$"` = true ]]; then
            SUPPORT_CHECKS+=("${fun:11}")
        fi
    done
    IFS=$_OLD_IFS
}

# get all supported install components functions
function get_all_supported_install_components() {
    _OLD_IFS=$IFS
    IFS=$'\n'
    for fun in $(declare -F); do
        if [[ `regexp_match "${fun:11}" "^install_"` = true ]]; then
            SUPPORTED_INSTALLATION_COMPONENTS+=("${fun:19}")
        fi
    done
    IFS=$_OLD_IFS
    # we don't need to expose "install_wget" to user.
    local DELETE_COMPONENTS=("wget")
    local REAL_COMPONENTS=()
    for component in ${SUPPORTED_INSTALLATION_COMPONENTS[@]}; do
        if [[ `contains_element "${DELETE_COMPONENTS[*]}" "${component}"` = false ]]; then
            REAL_COMPONENTS+=("${component}")
        fi
    done
    SUPPORTED_INSTALLATION_COMPONENTS=(${REAL_COMPONENTS[@]})
}

# exec all selected check stages
function check_stage() {
    print_function "STAGE" "checks starting"
    for fun in ${SUPPORT_CHECKS[@]}; do
        $fun
    done
    echo "All the checks are finished, the detailed information can be found in: $LOG_FILE"
}


###############################################################All Checks Definitions###############################################################
#########################
# This part defines all check functions such as tox_check and flake8_check
# We make a rule that all check functions are suffixed with _ check. e.g. tox_check, flake8_chek
#########################
# Tox check
function tox_check() {
    LATEST_PYTHON="py312"
    print_function "STAGE" "tox checks"
    # Set created py-env in $PATH for tox's creating virtual env
    activate
    # Ensure the permission of the scripts set correctly
    chmod +x $FLINK_PYTHON_DIR/../build-target/bin/*
    chmod +x $FLINK_PYTHON_DIR/dev/*

    if [[ ${BUILD_REASON} = 'IndividualCI' ]]; then
        # Only run test in latest python version triggered by a Git push
        $TOX_PATH -vv -c $FLINK_PYTHON_DIR/tox.ini -e ${LATEST_PYTHON} --recreate 2>&1 | tee -a $LOG_FILE
    else
        # Only run random selected python version in nightly CI.
        ENV_LIST_STRING=`$TOX_PATH -l -c $FLINK_PYTHON_DIR/tox.ini`
        _OLD_IFS=$IFS
        IFS=$'\n'
        ENV_LIST=(${ENV_LIST_STRING})
        IFS=$_OLD_IFS

        ENV_LIST_SIZE=${#ENV_LIST[@]}
        index=$(($RANDOM % ENV_LIST_SIZE))
        $TOX_PATH -vv -c $FLINK_PYTHON_DIR/tox.ini -e ${ENV_LIST[$index]} --recreate 2>&1 | tee -a $LOG_FILE
    fi

    TOX_RESULT=$((grep -c "congratulations :)" "$LOG_FILE") 2>&1)
    if [ $TOX_RESULT -eq '0' ]; then
        print_function "STAGE" "tox checks... [FAILED]"
    else
        print_function "STAGE" "tox checks... [SUCCESS]"
    fi
    # Reset the $PATH
    deactivate

    # If check failed, stop the running script.
    if [ $TOX_RESULT -eq '0' ]; then
        exit 1
    fi
}

# Flake8 check
function flake8_check() {
    local PYTHON_SOURCE="$(find . \( -path ./dev -o -path ./.tox \) -prune -o -type f -name "*.py" -print )"

    print_function "STAGE" "flake8 checks"
    if [ ! -f "$FLAKE8_PATH" ]; then
        echo "For some unknown reasons, the flake8 package is not complete,\
        you should exec the script with the parameter: -f"
    fi

    if [[ ! "$PYTHON_SOURCE" ]]; then
        echo "No python files found!  Something is wrong exiting."
        exit 1;
    fi

    # the return value of a pipeline is the status of the last command to exit
    # with a non-zero status or zero if no command exited with a non-zero status
    set -o pipefail
    ($FLAKE8_PATH  --config=tox.ini $PYTHON_SOURCE) 2>&1 | tee -a $LOG_FILE

    PYCODESTYLE_STATUS=$?
    if [ $PYCODESTYLE_STATUS -ne 0 ]; then
        print_function "STAGE" "flake8 checks... [FAILED]"
        # Stop the running script.
        exit 1;
    else
        print_function "STAGE" "flake8 checks... [SUCCESS]"
    fi
}

# Sphinx check
function sphinx_check() {
    export SPHINXBUILD=$SPHINX_PATH
    # cd to $FLINK_PYTHON_DIR
    pushd "$FLINK_PYTHON_DIR"/docs &> /dev/null
    make clean

    # the return value of a pipeline is the status of the last command to exit
    # with a non-zero status or zero if no command exited with a non-zero status
    set -o pipefail
    (SPHINXOPTS="-a -W" make html) 2>&1 | tee -a $LOG_FILE

    SPHINXBUILD_STATUS=$?
    if [ $SPHINXBUILD_STATUS -ne 0 ]; then
        print_function "STAGE" "sphinx checks... [FAILED]"
        # Stop the running script.
        exit 1;
    else
        print_function "STAGE" "sphinx checks... [SUCCESS]"
    fi
    popd
}

# mypy check
function mypy_check() {
    print_function "STAGE" "mypy checks"

    # the return value of a pipeline is the status of the last command to exit
    # with a non-zero status or zero if no command exited with a non-zero status
    set -o pipefail

    (${MYPY_PATH} --install-types --non-interactive --config-file tox.ini) 2>&1 | tee -a ${LOG_FILE}
    TYPE_HINT_CHECK_STATUS=$?
    if [ ${TYPE_HINT_CHECK_STATUS} -ne 0 ]; then
        print_function "STAGE" "mypy checks... [FAILED]"
        # Stop the running script.
        exit 1;
    else
        print_function "STAGE" "mypy checks... [SUCCESS]"
    fi
}
###############################################################All Checks Definitions###############################################################

# CURRENT_DIR is "flink/flink-python/dev/"
CURRENT_DIR="$(cd "$( dirname "$0" )" && pwd)"

# FLINK_PYTHON_DIR is "flink/flink-python"
FLINK_PYTHON_DIR=$(dirname "$CURRENT_DIR")

PYPROJECT_PATH="${FLINK_PYTHON_DIR}/pyproject.toml"

# uv home path
if [ -z "${FLINK_UV_HOME+x}" ]; then
    UV_HOME="$CURRENT_DIR/.uv"
    ENV_HOME="$UV_HOME"
else
    UV_HOME=$FLINK_UV_HOME
    ENV_HOME="${UV_PREFIX-$UV_HOME}"
fi

# uv path
UV_PATH=$UV_HOME/bin/uv

# pip path
PIP_PATH=$ENV_HOME/bin/pip

# tox path
TOX_PATH=$ENV_HOME/bin/tox

# flake8 path
FLAKE8_PATH=$ENV_HOME/bin/flake8

# sphinx path
SPHINX_PATH=$ENV_HOME/bin/sphinx-build

# mypy path
MYPY_PATH=$ENV_HOME/bin/mypy

_OLD_PATH="$PATH"

SUPPORT_OS=("Darwin" "Linux")

# the file stores the success step in installing progress.
STAGE_FILE=$CURRENT_DIR/.stage.txt

# the dir includes all kinds of py env installed.
VIRTUAL_ENV=$UV_HOME/envs

LOG_DIR=$CURRENT_DIR/log

if [ "$FLINK_IDENT_STRING" == "" ]; then
    FLINK_IDENT_STRING="$USER"
fi
if [ "$HOSTNAME" == "" ]; then
    HOSTNAME="$HOST"
fi

# the log file stores the checking result.
LOG_FILE=$LOG_DIR/flink-$FLINK_IDENT_STRING-python-$HOSTNAME.log
create_dir $LOG_DIR

# clean LOG_FILE content
echo >$LOG_FILE

# static version of uv that we use across all envs
UV_VERSION=0.7.20

# location of uv installation script
UV_INSTALL_SH=$CURRENT_DIR/download/uv.sh

# stage "install" includes the num of steps.
STAGE_INSTALL_STEPS=6

# whether force to restart the script.
FORCE_START=0

SUPPORT_CHECKS=()

# search all supported check functions and put them into SUPPORT_CHECKS array
get_all_supported_checks

EXCLUDE_CHECKS=""

INCLUDE_CHECKS=""

SUPPORTED_INSTALLATION_COMPONENTS=()

# search all supported install functions and put them into SUPPORTED_INSTALLATION_COMPONENTS array
get_all_supported_install_components

INSTALLATION_COMPONENTS=()

# whether remove the installed python environment.
CLEAN_UP_FLAG=0

# parse_opts
USAGE="
usage: $0 [options]
-h          print this help message and exit
-f          force to exec from the progress of installing environment
-s [basic,py_env,tox,flake8,sphinx,mypy,all]
            install environment with specified components which split by comma(,)
            note:
                This option is used to install environment components and will skip all subsequent checks,
                so do not use this option with -e,-i simultaneously.
-e [tox,flake8,sphinx,mypy]
            exclude checks which split by comma(,)
-i [tox,flake8,sphinx,mypy]
            include checks which split by comma(,)
-l          list all checks supported.
Examples:
  ./lint-python.sh -s basic        =>  install environment with basic components.
  ./lint-python.sh -s all          =>  install environment with all components such as python env,tox,flake8,sphinx,mypy etc.
  ./lint-python.sh -s tox,flake8   =>  install environment with tox,flake8.
  ./lint-python.sh -s tox -f       =>  reinstall environment with tox.
  ./lint-python.sh -e tox,flake8   =>  exclude checks tox,flake8.
  ./lint-python.sh -i flake8       =>  include checks flake8.
  ./lint-python.sh                 =>  exec all checks.
  ./lint-python.sh -f              =>  reinstall environment with all components and exec all checks.
  ./lint-python.sh -l              =>  list all checks supported.
  ./lint-python.sh -r              =>  clean up python environment.
"
while getopts "hfs:i:e:lr" arg; do
    case "$arg" in
        h)
            printf "%s\\n" "$USAGE"
            exit 2
            ;;
        f)
            FORCE_START=1
            ;;
        s)
            INSTALLATION_COMPONENTS=($(echo $OPTARG | tr ',' ' ' ))
            ;;
        e)
            EXCLUDE_CHECKS=($(echo $OPTARG | tr ',' ' ' ))
            ;;
        i)
            INCLUDE_CHECKS=($(echo $OPTARG | tr ',' ' ' ))
            ;;
        l)
            printf "current supported checks includes:\n"
            for fun in ${SUPPORT_CHECKS[@]}; do
                echo ${fun%%_check*}
            done
            exit 2
            ;;
        r)
            printf "clean up python environment:\n"
            CLEAN_UP_FLAG=1
            ;;
        ?)
            printf "ERROR: did not recognize option '%s', please try -h\\n" "$1"
            exit 1
            ;;
    esac
done

# decides whether to skip check stage
skip_checks=0

if [[ ${CLEAN_UP_FLAG} -eq 1 ]]; then
    printf "clean up python environment"
    rm -rf ${UV_HOME}
    rm -rf ${STAGE_FILE}
    rm -rf ${FLINK_PYTHON_DIR}/.tox
    skip_checks=1
fi

if [ ! -z "$INSTALLATION_COMPONENTS" ]; then
    parse_component_args
    skip_checks=1
fi

# collect checks according to the options
collect_checks

# If exec the script with the param: -f, all progress will be re-run
if [ $FORCE_START -eq 1 ]; then
    STAGE="install"
    STEP=0
    checkpoint_stage $STAGE $STEP
else
    restore_stage
fi

# install environment
if [[ ${CLEAN_UP_FLAG} -eq 0 ]]; then
    install_environment
fi

pushd "$FLINK_PYTHON_DIR" &> /dev/null
# exec all selected checks
if [ $skip_checks -eq 0 ]; then
    check_stage
fi
