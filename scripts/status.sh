#!/usr/bin/env bash
# What is asleep right now, and what will be restored.
. "$(dirname "$0")/common.sh"

t="$(now)"
T list-sessions -F '#{session_id} #{?@hibernate_asleep,#{@hibernate_asleep},0} #{session_name}' | while read -r id asleep name; do
  [ "$asleep" != 0 ] || continue
  echo "$name  (asleep $(( (t - asleep) / 60 )) min)"
  T list-panes -s -t "$id" -F '#{pane_id} #{window_index}.#{pane_index} #{@hibernate_state}' |
  while read -r pane idx state; do
    [ -n "$state" ] || continue
    cmd="$(T show -pqv -t "$pane" @hibernate_cmd)"
    printf '  %-6s %-8s %s\n' "$idx" "$state" "$cmd"
  done
done
T list-sessions -F '#{@hibernate_asleep}' | grep -q . || echo "hibernate: nothing is asleep"
