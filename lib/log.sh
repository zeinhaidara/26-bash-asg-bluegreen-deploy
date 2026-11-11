#!/usr/bin/env bash
# Leveled logging helpers. Source this file; do not execute directly.

LOG_LEVEL="${LOG_LEVEL:-INFO}"

_log_level_num() {
	case "$1" in
	DEBUG) echo 0 ;;
	INFO) echo 1 ;;
	WARN) echo 2 ;;
	ERROR) echo 3 ;;
	*) echo 1 ;;
	esac
}

_log() {
	local level="$1"
	shift
	local threshold current
	threshold=$(_log_level_num "$LOG_LEVEL")
	current=$(_log_level_num "$level")
	if ((current >= threshold)); then
		printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
	fi
}

log_debug() { _log DEBUG "$@"; }
log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
