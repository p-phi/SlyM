#!/usr/bin/env bash
set -euo pipefail

# Get the current time in the format: HH:MM:SS
current_time=$(date '+%H:%M:%S')

# Output the result
echo '{"time": "'$current_time'", "message": "Current time retrieved successfully."}'
