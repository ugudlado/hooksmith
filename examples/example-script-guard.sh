#!/bin/bash
# Example script rule — guards against killing protected processes.
# This is a sample script that would be referenced by a script-type YAML rule.
source "$HOOKLIB"

read_input
COMMAND=$(get_field command)

# Check if trying to kill a protected process
if [[ "$COMMAND" =~ kill.*-9 ]]; then
  deny "Blocked: force-killing processes requires manual approval"
fi
