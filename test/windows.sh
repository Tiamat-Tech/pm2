#!/usr/bin/env bash
#
# PM2 test runner for Windows (Git Bash)
# Runs unit tests and Windows-compatible e2e tests
#
# Usage:
#   bash test/windows.sh
#

cd "$(dirname "$0")/.."

export PM2_SILENT="true"

mocha="npx mocha"
pm2="$(pwd)/bin/pm2"

# ==================== UNIT TESTS ====================

function reset {
    $pm2 uninstall all -s 2>/dev/null
    $pm2 link delete -s 2>/dev/null
    $pm2 kill -s 2>/dev/null
}

function runUnitTest {
    echo "[~] Starting unit test $1"
    reset
    $mocha --exit --bail "$1"
    RET=$?

    if [ $RET -ne 0 ]; then
        echo "[RETRY] $1 failed, retrying..."
        reset
        $mocha --bail --exit "$1"
        RET=$?

        if [ $RET -ne 0 ]; then
            echo "######## TEST FAILED: $1"
            UNIT_FAILED=1
        fi
    fi

    reset
}

UNIT_FAILED=0

reset

D=test/programmatic

runUnitTest $D/path_resolution.mocha.js
runUnitTest $D/modules.mocha.js
runUnitTest $D/instances.mocha.js
runUnitTest $D/reload-locker.mocha.js
runUnitTest $D/filter_env.mocha.js
runUnitTest $D/resurect_state.mocha.js
runUnitTest $D/programmatic.js
runUnitTest $D/namespace.mocha.js
runUnitTest $D/auto_restart.mocha.js
runUnitTest $D/containerizer.mocha.js
runUnitTest $D/api.mocha.js
# Excluded: lazy_api.mocha.js - timing-dependent, flaky on Windows CI
# Excluded: exp_backoff_restart_delay.mocha.js - timing-dependent exponential backoff test
runUnitTest $D/api.backward.compatibility.mocha.js
runUnitTest $D/custom_action.mocha.js
runUnitTest $D/logs.js
runUnitTest $D/watcher.js
runUnitTest $D/max_memory_limit.js
runUnitTest $D/cluster.mocha.js
runUnitTest $D/graceful.mocha.js
runUnitTest $D/inside.mocha.js
runUnitTest $D/misc_commands.js
runUnitTest $D/signals.js
runUnitTest $D/send_data_process.mocha.js
runUnitTest $D/json_validation.mocha.js
runUnitTest $D/env_switching.js
runUnitTest $D/configuration.mocha.js
runUnitTest $D/id.mocha.js
runUnitTest $D/god.mocha.js
runUnitTest $D/dump.mocha.js
runUnitTest $D/common.mocha.js
runUnitTest $D/fclone.mocha.js
runUnitTest $D/issues/json_env_passing_4080.mocha.js

D=test/interface

runUnitTest $D/bus.spec.mocha.js
runUnitTest $D/bus.fork.spec.mocha.js
runUnitTest $D/utility.mocha.js

echo "============== unit tests finished =============="

# ==================== E2E TESTS ====================

SRC=$(cd $(dirname "$0"); pwd)
source "${SRC}/e2e/include.sh"

set -e

E2E_FAILED=0

# Tests excluded on Windows:
#   startup.sh          - requires systemd/launchd
#   extra-lang.sh       - python3/php path differences
#   python-support.sh   - python3 path differences
#   nvm-node-version.sh - nvm not available on Windows
#   inside-pm2.sh       - relies on Linux process behavior
#   port-release.sh     - platform-specific port handling
#   reload.sh           - SIGINT signal delivery doesn't work on Windows
#                         (process.kill(pid, 'SIGINT') terminates immediately
#                         without triggering JS signal handlers)

# CLI
# runTest ./test/e2e/cli/reload.sh  # excluded: see above
runTest ./test/e2e/cli/start-app.sh
runTest ./test/e2e/cli/operate-regex.sh
runTest ./test/e2e/cli/app-configuration.sh
runTest ./test/e2e/cli/binary.sh
runTest ./test/e2e/cli/startOrX.sh
runTest ./test/e2e/cli/reset.sh
runTest ./test/e2e/cli/env-refresh.sh
runTest ./test/e2e/cli/multiparam.sh
runTest ./test/e2e/cli/smart-start.sh
runTest ./test/e2e/cli/args.sh
runTest ./test/e2e/cli/attach.sh
runTest ./test/e2e/cli/serve.sh

runTest ./test/e2e/esmodule.sh

runTest ./test/e2e/cli/monit.sh
runTest ./test/e2e/cli/cli-actions-1.sh
runTest ./test/e2e/cli/cli-actions-2.sh
runTest ./test/e2e/cli/dump.sh
runTest ./test/e2e/cli/resurrect.sh
runTest ./test/e2e/cli/watch.sh
runTest ./test/e2e/cli/right-exit-code.sh
runTest ./test/e2e/cli/fork.sh
runTest ./test/e2e/cli/piped-config.sh

# PROCESS FILES
runTest ./test/e2e/process-file/json-file.sh
runTest ./test/e2e/process-file/yaml-configuration.sh
runTest ./test/e2e/process-file/json-reload.sh
runTest ./test/e2e/process-file/app-config-update.sh
runTest ./test/e2e/process-file/js-configuration.sh
runTest ./test/e2e/process-file/homogen-json-action.sh

# INTERNALS
runTest ./test/e2e/internals/wait-ready-event.sh
runTest ./test/e2e/internals/daemon-paths-override.sh
runTest ./test/e2e/internals/source_map.sh
runTest ./test/e2e/internals/wrapped-fork.sh
runTest ./test/e2e/internals/infinite-loop.sh
runTest ./test/e2e/internals/options-via-env.sh
runTest ./test/e2e/internals/increment-var.sh
runTest ./test/e2e/internals/start-consistency.sh

# MISC
runTest ./test/e2e/misc/misc.sh
runTest ./test/e2e/misc/instance-number.sh

# LOGS
runTest ./test/e2e/logs/log-json.sh
runTest ./test/e2e/logs/log-custom.sh
runTest ./test/e2e/logs/log-reload.sh
runTest ./test/e2e/logs/log-entire.sh
runTest ./test/e2e/logs/log-null.sh
runTest ./test/e2e/logs/log-create-not-exist-dir.sh
runTest ./test/e2e/logs/log-namespace.sh

# MODULES
runTest ./test/e2e/modules/get-set.sh
runTest ./test/e2e/modules/module.sh
runTest ./test/e2e/modules/module-safeguard.sh

$pm2 kill

echo "============== e2e tests finished =============="

# Final result
if [ $UNIT_FAILED -ne 0 ]; then
    echo "SOME UNIT TESTS FAILED"
    exit 1
fi

echo "ALL TESTS PASSED"
