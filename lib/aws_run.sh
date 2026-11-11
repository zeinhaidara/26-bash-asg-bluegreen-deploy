#!/usr/bin/env bash
# Wraps every aws CLI invocation so dry-run mode can intercept it in one place.
# Source this file; do not execute directly.

DRY_RUN="${DRY_RUN:-true}"

# aws_run <aws-cli-args...>
# Read-only calls (describe-*, wait) always run for real so the script can
# make decisions; mutating calls are skipped and logged when DRY_RUN=true.
aws_run() {
	local sub="$2"
	if [[ "$DRY_RUN" == "true" ]] && [[ "$sub" != describe-* ]] && [[ "$sub" != "wait" ]]; then
		log_info "[dry-run] would run: aws $*"
		return 0
	fi
	log_debug "running: aws $*"
	aws "$@"
}
