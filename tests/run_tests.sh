#!/usr/bin/env bash
# Hand-rolled test runner for deploy.sh. No real AWS calls are ever made:
# PATH is pointed at tests/fakebin/aws, a fake CLI that records invocations.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DEPLOY="$REPO_ROOT/scripts/deploy.sh"

PASS_COUNT=0
FAIL_COUNT=0

setup_env() {
	WORK_DIR=$(mktemp -d)
	export FAKE_AWS_CALL_LOG="$WORK_DIR/calls.log"
	export FAKE_HEALTHY_SEQUENCE_FILE="$WORK_DIR/sequence"
	touch "$FAKE_AWS_CALL_LOG" "$FAKE_HEALTHY_SEQUENCE_FILE"
	export PATH="$TESTS_DIR/fakebin:$PATH"
}

teardown_env() {
	rm -rf "$WORK_DIR"
}

seq_set() {
	printf '%s\n' "$@" >"$FAKE_HEALTHY_SEQUENCE_FILE"
}

call_log_contains() {
	grep -qF -- "$1" "$FAKE_AWS_CALL_LOG"
}

run_case() {
	setup_env
	local status=0
	if "$@" >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
		status=0
	else
		status=$?
	fi
	export LAST_STATUS="$status"
	export LAST_WORK_DIR="$WORK_DIR"
}

assert_eq() {
	local expected="$1" actual="$2" msg="$3"
	if [[ "$expected" != "$actual" ]]; then
		echo "FAIL: $msg (expected '$expected', got '$actual')"
		FAIL_COUNT=$((FAIL_COUNT + 1))
		return 1
	fi
	return 0
}

assert_empty_file() {
	local file="$1" msg="$2"
	if [[ -s "$file" ]]; then
		echo "FAIL: $msg"
		FAIL_COUNT=$((FAIL_COUNT + 1))
		return 1
	fi
	return 0
}

pass() {
	echo "PASS: $1"
	PASS_COUNT=$((PASS_COUNT + 1))
}

# --- test: dry-run is the default, no aws mutations happen ---
run_case "$DEPLOY" --blue-asg blue-asg --green-asg green-asg \
	--target-group-arn arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/app/abc \
	--target-capacity 5
if assert_eq 0 "$LAST_STATUS" "dry-run exits 0" &&
	assert_empty_file "$FAKE_AWS_CALL_LOG" "dry-run makes no aws calls"; then
	pass "dry-run default makes no aws calls"
fi
teardown_env

# --- test: healthy canary and healthy cutover leads to full swap ---
setup_env
seq_set 1 5
"$DEPLOY" --blue-asg blue-asg --green-asg green-asg \
	--target-group-arn arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/app/abc \
	--target-capacity 5 --canary-percent 20 --health-check-interval 0 --apply \
	>/dev/null 2>&1
status=$?
if assert_eq 0 "$status" "happy path exits 0" &&
	call_log_contains "autoscaling attach-load-balancer-target-groups --auto-scaling-group-name green-asg" &&
	call_log_contains "autoscaling update-auto-scaling-group --auto-scaling-group-name green-asg --desired-capacity 1" &&
	call_log_contains "autoscaling update-auto-scaling-group --auto-scaling-group-name green-asg --desired-capacity 5" &&
	call_log_contains "autoscaling detach-load-balancer-target-groups --auto-scaling-group-name blue-asg" &&
	call_log_contains "autoscaling update-auto-scaling-group --auto-scaling-group-name blue-asg --desired-capacity 0"; then
	pass "happy path cuts over blue to green"
fi
teardown_env

# --- test: canary fails health check, rollback, blue untouched ---
setup_env
seq_set 0 0
set +e
"$DEPLOY" --blue-asg blue-asg --green-asg green-asg \
	--target-group-arn arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/app/abc \
	--target-capacity 5 --canary-percent 20 --health-check-attempts 2 --health-check-interval 0 --apply \
	>/dev/null 2>&1
status=$?
set -e
if assert_eq 1 "$status" "failed canary exits 1" &&
	call_log_contains "autoscaling update-auto-scaling-group --auto-scaling-group-name green-asg --desired-capacity 0" &&
	call_log_contains "autoscaling detach-load-balancer-target-groups --auto-scaling-group-name green-asg" &&
	! call_log_contains "blue-asg --desired-capacity 0" &&
	! call_log_contains "detach-load-balancer-target-groups --auto-scaling-group-name blue-asg"; then
	pass "failed canary rolls back and leaves blue untouched"
fi
teardown_env

# --- test: canary passes but full cutover health check fails, rollback ---
setup_env
seq_set 1 0 0
set +e
"$DEPLOY" --blue-asg blue-asg --green-asg green-asg \
	--target-group-arn arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/app/abc \
	--target-capacity 5 --canary-percent 20 --health-check-attempts 2 --health-check-interval 0 --apply \
	>/dev/null 2>&1
status=$?
set -e
if assert_eq 1 "$status" "failed cutover exits 1" &&
	call_log_contains "autoscaling update-auto-scaling-group --auto-scaling-group-name green-asg --desired-capacity 5" &&
	call_log_contains "autoscaling update-auto-scaling-group --auto-scaling-group-name green-asg --desired-capacity 0" &&
	! call_log_contains "blue-asg --desired-capacity 0"; then
	pass "failed cutover health check rolls back without touching blue"
fi
teardown_env

# --- test: missing required argument fails fast with no aws calls ---
setup_env
set +e
"$DEPLOY" --blue-asg blue-asg --green-asg green-asg >/dev/null 2>&1
status=$?
set -e
if assert_eq 1 "$status" "missing arg exits 1" &&
	assert_empty_file "$FAKE_AWS_CALL_LOG" "missing arg makes no aws calls"; then
	pass "missing required argument fails before any aws call"
fi
teardown_env

echo ""
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
if ((FAIL_COUNT > 0)); then
	exit 1
fi
