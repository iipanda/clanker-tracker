#!/bin/sh
# Claude Code status line — styled after robbyrussell Oh My Zsh theme

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir=$(basename "$cwd")
model=$(echo "$input" | jq -r '.model.display_name // ""')

# Context window: sum all input token components from current_usage to get the
# precise context window size. These reflect the real API call and survive --resume.
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
# Precise token count: input + cache_creation + cache_read (all are input to the model)
ctx_tokens=$(echo "$input" | jq -r '
  .context_window.current_usage |
  if . then
    ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
  else empty end')

# Rate limits
five_h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
weekly=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Git branch
branch=""
if [ -n "$cwd" ] && [ -d "$cwd/.git" ] || git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" -c core.hooksPath=/dev/null symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" -c core.hooksPath=/dev/null rev-parse --short HEAD 2>/dev/null)
fi

# Format token count as human-readable (e.g. 15.2k, 1.0M)
format_tokens() {
  tokens=$1
  if [ -z "$tokens" ] || [ "$tokens" = "null" ]; then
    echo "0"
    return
  fi
  if [ "$tokens" -ge 1000000 ]; then
    printf "%.1fM" "$(echo "$tokens / 1000000" | bc -l)"
  elif [ "$tokens" -ge 1000 ]; then
    printf "%.1fk" "$(echo "$tokens / 1000" | bc -l)"
  else
    echo "$tokens"
  fi
}

# Format context size
format_ctx_size() {
  size=$1
  if [ -z "$size" ] || [ "$size" = "null" ]; then
    echo "?"
    return
  fi
  if [ "$size" -ge 1000000 ]; then
    printf "%.0fM" "$(echo "$size / 1000000" | bc -l)"
  else
    printf "%.0fk" "$(echo "$size / 1000" | bc -l)"
  fi
}

# Build context part — use precise token sum, fall back to percentage-derived estimate
ctx_part=""
if [ -n "$ctx_tokens" ] && [ -n "$ctx_size" ]; then
  pct_display=$(printf "%.0f" "${ctx_pct:-0}")
  ctx_part=" | Context: $(format_tokens $ctx_tokens)/$(format_ctx_size $ctx_size) (${pct_display}%)"
elif [ -n "$ctx_pct" ] && [ -n "$ctx_size" ]; then
  pct_display=$(printf "%.0f" "$ctx_pct")
  ctx_part=" | Context: ${pct_display}%/$(format_ctx_size $ctx_size)"
fi

# Build rate limits part
limits_part=""
if [ -n "$five_h" ] || [ -n "$weekly" ]; then
  limits_part=" |"
  if [ -n "$five_h" ]; then
    five_int=$(printf "%.0f" "$five_h")
    limits_part="${limits_part} 5h:${five_int}%"
  fi
  if [ -n "$weekly" ]; then
    weekly_int=$(printf "%.0f" "$weekly")
    limits_part="${limits_part} 7d:${weekly_int}%"
  fi
fi

# Build git part
git_part=""
if [ -n "$branch" ]; then
  git_part=" git:(${branch})"
fi

printf "\033[1;32m➜\033[0m  \033[1;36m%s\033[0m\033[33m%s\033[0m | %s%s%s" \
  "$dir" "$git_part" "$model" "$ctx_part" "$limits_part"
