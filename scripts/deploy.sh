#!/usr/bin/env bash
# Blue/green deploy with a canary gate for two EC2 Auto Scaling Groups
# sharing one target group. See README.md for the full flow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"
# shellcheck source=../lib/aws_run.sh
source "$SCRIPT_DIR/../lib/aws_run.sh"

usage() {
	cat <<'EOF'
Usage: deploy.sh --blue-asg NAME --green-asg NAME --target-group-arn ARN \
                  --target-capacity N [--canary-percent N] \
                  [--health-check-attempts N] [--health-check-interval SECONDS] \
                  [--apply]

Defaults to dry-run (no mutating aws calls are issued). Pass --apply to
actually attach/detach/scale the Auto Scaling Groups.
EOF
}

trap 'log_error "deploy failed at line $LINENO"' ERR

BLUE_ASG=""
GREEN_ASG=""
TARGET_GROUP_ARN=""
TARGET_CAPACITY=""
CANARY_PERCENT=20
HEALTH_CHECK_ATTEMPTS=5
HEALTH_CHECK_INTERVAL=5

while [[ $# -gt 0 ]]; do
	case "$1" in
	--blue-asg)
		BLUE_ASG="$2"
		shift 2
		;;
	--green-asg)
		GREEN_ASG="$2"
		shift 2
		;;
	--target-group-arn)
		TARGET_GROUP_ARN="$2"
		shift 2
		;;
	--target-capacity)
		TARGET_CAPACITY="$2"
		shift 2
		;;
	--canary-percent)
		CANARY_PERCENT="$2"
		shift 2
		;;
	--health-check-attempts)
		HEALTH_CHECK_ATTEMPTS="$2"
		shift 2
		;;
	--health-check-interval)
		HEALTH_CHECK_INTERVAL="$2"
		shift 2
		;;
	--apply)
		DRY_RUN=false
		shift
		;;
	--dry-run)
		DRY_RUN=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		log_error "unknown argument: $1"
		usage
		exit 1
		;;
	esac
done

for required in BLUE_ASG GREEN_ASG TARGET_GROUP_ARN TARGET_CAPACITY; do
	if [[ -z "${!required}" ]]; then
		log_error "missing required argument for ${required,,}"
		usage
		exit 1
	fi
done

if [[ "$DRY_RUN" == "true" ]]; then
	log_warn "running in dry-run mode, no changes will be made (pass --apply to execute)"
else
	log_warn "running in apply mode, changes will be made to: $BLUE_ASG, $GREEN_ASG"
fi

canary_capacity() {
	local total="$1" percent="$2"
	local capacity=$((total * percent / 100))
	if ((capacity < 1)); then
		capacity=1
	fi
	echo "$capacity"
}

attach_to_target_group() {
	local asg="$1"
	log_info "attaching $asg to target group $TARGET_GROUP_ARN"
	aws_run autoscaling attach-load-balancer-target-groups \
		--auto-scaling-group-name "$asg" \
		--target-group-arns "$TARGET_GROUP_ARN"
}

detach_from_target_group() {
	local asg="$1"
	log_info "detaching $asg from target group $TARGET_GROUP_ARN"
	aws_run autoscaling detach-load-balancer-target-groups \
		--auto-scaling-group-name "$asg" \
		--target-group-arns "$TARGET_GROUP_ARN"
}

set_capacity() {
	local asg="$1" capacity="$2"
	log_info "setting $asg desired capacity to $capacity"
	aws_run autoscaling update-auto-scaling-group \
		--auto-scaling-group-name "$asg" \
		--desired-capacity "$capacity" \
		--min-size 0
}

count_healthy_targets() {
	aws_run elbv2 describe-target-health \
		--target-group-arn "$TARGET_GROUP_ARN" \
		--query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
		--output text
}

wait_for_healthy() {
	local needed="$1" attempt healthy
	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] assuming health check passes, skipping describe-target-health"
		return 0
	fi
	for ((attempt = 1; attempt <= HEALTH_CHECK_ATTEMPTS; attempt++)); do
		healthy=$(count_healthy_targets)
		log_info "health check attempt $attempt/$HEALTH_CHECK_ATTEMPTS: $healthy/$needed healthy targets"
		if ((healthy >= needed)); then
			return 0
		fi
		sleep "$HEALTH_CHECK_INTERVAL"
	done
	return 1
}

rollback_canary() {
	log_error "canary health check failed, rolling back $GREEN_ASG"
	set_capacity "$GREEN_ASG" 0
	detach_from_target_group "$GREEN_ASG"
	log_error "rollback complete, $BLUE_ASG remains the active deployment"
}

cutover() {
	log_info "canary healthy, proceeding with full cutover to $GREEN_ASG"
	set_capacity "$GREEN_ASG" "$TARGET_CAPACITY"
	wait_for_healthy "$TARGET_CAPACITY" || {
		log_error "full cutover health check failed, rolling back $GREEN_ASG"
		rollback_canary
		exit 1
	}
	detach_from_target_group "$BLUE_ASG"
	set_capacity "$BLUE_ASG" 0
	log_info "cutover complete: $GREEN_ASG is now serving traffic, $BLUE_ASG scaled to 0"
}

main() {
	local canary_size
	canary_size=$(canary_capacity "$TARGET_CAPACITY" "$CANARY_PERCENT")
	log_info "starting canary: $GREEN_ASG at $canary_size/$TARGET_CAPACITY instances ($CANARY_PERCENT%)"

	attach_to_target_group "$GREEN_ASG"
	set_capacity "$GREEN_ASG" "$canary_size"

	if wait_for_healthy "$canary_size"; then
		cutover
	else
		rollback_canary
		exit 1
	fi
}

main
