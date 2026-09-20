#!/usr/bin/env bash
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
bash "$D/run-tests.sh"     || rc=1
bash "$D/install-tests.sh" || rc=1
exit $rc
