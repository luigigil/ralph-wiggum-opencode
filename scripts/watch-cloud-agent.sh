#!/bin/bash
# Ralph Wiggum: Cloud Agent Watcher
# - Polls agent status until completion
# - Chains agents if task isn't done
# - Uses follow-up for nudges
# - Merges completed branches

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

POLL_INTERVAL=30        # seconds between status checks
MAX_CHAIN_DEPTH=10      # max agents to chain before giving up
FOLLOWUP_ATTEMPTS=3     # nudges before spawning new agent

# Token rotation thresholds (True Ralph: malloc/free at context limit)
TOKEN_THRESHOLD=50000   # Force-stop and rotate at this level
WARNING_THRESHOLD=45000 # Send wrapup warning at 90% of threshold
STOP_WAIT_TIMEOUT=60    # Max seconds to wait for STOPPED status

CONFIG_FILE="${WORKSPACE_ROOT:-.}/.cursor/ralph-config.json"
GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"

# =============================================================================
# HELPERS
# =============================================================================

get_api_key() {
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then echo "$CURSOR_API_KEY" && return 0; fi
  if [[ -f "$CONFIG_FILE" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$KEY" ]]; then echo "$KEY" && return 0; fi
  fi
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$GLOBAL_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$KEY" ]]; then echo "$KEY" && return 0; fi
  fi
  return 1
}

get_agent_status() {
  local agent_id="$1"
  local api_key="$2"
  
  curl -s "https://api.cursor.com/v0/agents/$agent_id" -u "$api_key:" 2>/dev/null
}

get_agent_conversation() {
  local agent_id="$1"
  local api_key="$2"
  
  curl -s "https://api.cursor.com/v0/agents/$agent_id/conversation" -u "$api_key:" 2>/dev/null
}

stop_agent() {
  local agent_id="$1"
  local api_key="$2"
  
  curl -s -X POST "https://api.cursor.com/v0/agents/$agent_id/stop" -u "$api_key:" 2>/dev/null
}

# Estimate tokens from conversation messages
# Uses chars/4 as base estimate, applies 1.3x multiplier for tool calls/context
estimate_tokens() {
  local conversation_json="$1"
  
  # Sum character counts of all message texts
  local total_chars
  total_chars=$(echo "$conversation_json" | jq -r '[.messages[]?.text // "" | length] | add // 0')
  
  # Base estimate: ~4 chars per token
  local base_tokens=$((total_chars / 4))
  
  # Apply 1.3x multiplier for tool calls, system prompts, file contents not visible in text
  local estimated=$((base_tokens * 13 / 10))
  
  echo "$estimated"
}

# Extract summary from last N assistant messages for continuation prompt
extract_context_summary() {
  local conversation_json="$1"
  local num_messages="${2:-3}"
  
  # Get last N assistant messages
  echo "$conversation_json" | jq -r --argjson n "$num_messages" '
    [.messages[] | select(.type == "assistant_message")] | .[-($n):] | 
    map("- " + (.text | split("\n")[0:3] | join(" ") | .[0:200])) | 
    join("\n")
  ' 2>/dev/null || echo "No context available"
}

send_followup() {
  local agent_id="$1"
  local api_key="$2"
  local message="$3"
  
  curl -s -X POST "https://api.cursor.com/v0/agents/$agent_id/followup" \
    -u "$api_key:" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg msg "$message" '{"prompt": {"text": $msg}}')" 2>/dev/null
}

spawn_continuation_agent() {
  local workspace="$1"
  local prev_agent_id="$2"
  local prev_branch="$3"
  local iteration="$4"
  
  "$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace"
}

# Spawn a new agent with context from the stopped agent's conversation
spawn_with_context() {
  local workspace="$1"
  local context_summary="$2"
  local stop_reason="${3:-context_limit}"
  
  # Export context for spawn-cloud-agent.sh to use
  export RALPH_CONTEXT_SUMMARY="$context_summary"
  export RALPH_STOP_REASON="$stop_reason"
  
  "$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace"
  
  unset RALPH_CONTEXT_SUMMARY
  unset RALPH_STOP_REASON
}

# Wait for agent to reach STOPPED status
wait_for_stopped() {
  local agent_id="$1"
  local api_key="$2"
  local timeout="${3:-$STOP_WAIT_TIMEOUT}"
  
  local elapsed=0
  local interval=2
  
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(get_agent_status "$agent_id" "$api_key" | jq -r '.status // "UNKNOWN"')
    
    if [[ "$status" == "STOPPED" ]]; then
      return 0
    fi
    
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  return 1  # Timeout
}

check_task_complete() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi
  
  # Count unchecked criteria (supports "- [ ]" and "1. [ ]" formats)
  # Note: || must be OUTSIDE $() to avoid double output
  local unchecked
  unchecked=$(grep -c '\[ \]' "$task_file" 2>/dev/null) || unchecked=0
  
  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

# =============================================================================
# MAIN WATCHER LOOP
# =============================================================================

watch_agent() {
  local agent_id="$1"
  local workspace="$2"
  local chain_depth="${3:-1}"
  local followup_count=0
  local warning_sent=0  # Track if wrapup warning was sent
  
  API_KEY=$(get_api_key) || {
    echo "❌ No API key configured" >&2
    exit 1
  }
  
  echo "═══════════════════════════════════════════════════════════════════"
  echo "👁️  Ralph Watcher: Monitoring Cloud Agent (True Ralph Mode)"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "Agent ID:      $agent_id"
  echo "Workspace:     $workspace"
  echo "Chain depth:   $chain_depth / $MAX_CHAIN_DEPTH"
  echo "Token limit:   ${TOKEN_THRESHOLD} (warning at ${WARNING_THRESHOLD})"
  echo "Monitor:       https://cursor.com/agents?id=$agent_id"
  echo ""
  echo "Polling every ${POLL_INTERVAL}s... (Ctrl+C to stop)"
  echo ""
  
  while true; do
    # Get agent status
    RESPONSE=$(get_agent_status "$agent_id" "$API_KEY")
    STATUS=$(echo "$RESPONSE" | jq -r '.status // "UNKNOWN"')
    SUMMARY=$(echo "$RESPONSE" | jq -r '.summary // ""')
    BRANCH=$(echo "$RESPONSE" | jq -r '.target.branchName // ""')
    
    TIMESTAMP=$(date '+%H:%M:%S')
    
    # =========================================================================
    # TOKEN MONITORING (True Ralph: malloc/free at context limit)
    # =========================================================================
    if [[ "$STATUS" == "RUNNING" ]]; then
      CONVERSATION=$(get_agent_conversation "$agent_id" "$API_KEY")
      ESTIMATED_TOKENS=$(estimate_tokens "$CONVERSATION")
      
      # Display token status
      local token_pct=$((ESTIMATED_TOKENS * 100 / TOKEN_THRESHOLD))
      local token_bar=""
      for i in $(seq 1 10); do
        if [[ $((i * 10)) -le $token_pct ]]; then
          token_bar="${token_bar}█"
        else
          token_bar="${token_bar}░"
        fi
      done
      
      # Check for force-stop threshold
      if [[ $ESTIMATED_TOKENS -ge $TOKEN_THRESHOLD ]]; then
        echo "[$TIMESTAMP] 🔴 Token limit reached: ${ESTIMATED_TOKENS}/${TOKEN_THRESHOLD}"
        echo "   Force-stopping agent for context rotation..."
        
        # Stop the agent
        stop_agent "$agent_id" "$API_KEY" >/dev/null
        
        # Wait for STOPPED status
        echo "   Waiting for agent to stop..."
        if ! wait_for_stopped "$agent_id" "$API_KEY"; then
          echo "   ⚠️  Timeout waiting for STOPPED status, proceeding anyway"
        fi
        
        # Fetch final conversation and extract context
        FINAL_CONVERSATION=$(get_agent_conversation "$agent_id" "$API_KEY")
        CONTEXT_SUMMARY=$(extract_context_summary "$FINAL_CONVERSATION" 3)
        
        echo ""
        echo "📋 Context from stopped agent:"
        echo "$CONTEXT_SUMMARY" | sed 's/^/   /'
        echo ""
        
        # Check chain depth
        if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
          echo "⚠️  Max chain depth ($MAX_CHAIN_DEPTH) reached. Stopping."
          echo "   Continue manually: cd $workspace && git checkout $BRANCH"
          exit 1
        fi
        
        echo "🔄 Spawning fresh agent with context handoff..."
        echo ""
        
        # Spawn new agent with context
        NEW_AGENT_OUTPUT=$(spawn_with_context "$workspace" "$CONTEXT_SUMMARY" "context_limit" 2>&1)
        NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
        
        if [[ -n "$NEW_AGENT_ID" ]]; then
          echo "$NEW_AGENT_OUTPUT"
          echo ""
          # Recursive watch with fresh context
          watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
          exit $?
        else
          echo "❌ Failed to spawn continuation agent"
          echo "$NEW_AGENT_OUTPUT"
          exit 1
        fi
      
      # Check for warning threshold
      elif [[ $ESTIMATED_TOKENS -ge $WARNING_THRESHOLD && $warning_sent -eq 0 ]]; then
        echo "[$TIMESTAMP] 🟡 Context warning: ${ESTIMATED_TOKENS}/${TOKEN_THRESHOLD} [${token_bar}] ${token_pct}%"
        echo "   Sending wrapup warning to agent..."
        
        WRAPUP_MESSAGE="⚠️ CONTEXT LIMIT APPROACHING - You are at ~${token_pct}% of your context window.

REQUIRED ACTIONS:
1. Finish your current file edit
2. Commit with descriptive message: git add -A && git commit -m 'ralph: [what you did]'
3. Push your changes: git push
4. Update .ralph/progress.md with:
   - What you accomplished
   - What's next (the immediate next step)
   - Any blockers or notes

After these steps, you may be rotated to a fresh agent with clean context. Leave the codebase in a working state."
        
        send_followup "$agent_id" "$API_KEY" "$WRAPUP_MESSAGE" >/dev/null
        warning_sent=1
        echo "   ✓ Wrapup warning sent"
      else
        echo "[$TIMESTAMP] 🔄 Running [${token_bar}] ${ESTIMATED_TOKENS}/${TOKEN_THRESHOLD} tokens (~${token_pct}%)"
      fi
      
      followup_count=0
    fi
    
    case "$STATUS" in
      "RUNNING")
        # Token monitoring handled above, nothing more to do here
        ;;
        
      "FINISHED")
        echo "[$TIMESTAMP] ✅ Agent finished!"
        echo ""
        echo "Summary: $SUMMARY"
        echo "Branch:  $BRANCH"
        echo ""
        
        # Pull the branch and check if task is complete
        cd "$workspace"
        git fetch origin "$BRANCH" 2>/dev/null || true
        git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH" 2>/dev/null || true
        git pull origin "$BRANCH" 2>/dev/null || true
        
        TASK_STATUS=$(check_task_complete "$workspace")
        
        if [[ "$TASK_STATUS" == "COMPLETE" ]]; then
          echo "🎉 RALPH COMPLETE! All criteria satisfied."
          echo ""
          echo "Branch '$BRANCH' contains the completed work."
          echo "Merge it when ready: git checkout main && git merge $BRANCH"
          exit 0
          
        elif [[ "$TASK_STATUS" == "NO_TASK_FILE" ]]; then
          echo "⚠️  No RALPH_TASK.md found. Cannot verify completion."
          exit 0
          
        else
          REMAINING=$(echo "$TASK_STATUS" | cut -d: -f2)
          echo "📋 Task incomplete: $REMAINING criteria remaining"
          echo ""
          
          if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
            echo "⚠️  Max chain depth ($MAX_CHAIN_DEPTH) reached. Stopping."
            echo "   Continue manually: cd $workspace && git checkout $BRANCH"
            exit 1
          fi
          
          echo "🔗 Chaining: Spawning new agent to continue..."
          echo ""
          
          # Spawn continuation agent
          NEW_AGENT_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace" 2>&1)
          NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
          
          if [[ -n "$NEW_AGENT_ID" ]]; then
            echo "$NEW_AGENT_OUTPUT"
            echo ""
            # Recursive watch
            watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
            exit $?
          else
            echo "❌ Failed to spawn continuation agent"
            echo "$NEW_AGENT_OUTPUT"
            exit 1
          fi
        fi
        ;;
        
      "STOPPED")
        echo "[$TIMESTAMP] ⏸️  Agent stopped"
        
        if [[ "$followup_count" -lt "$FOLLOWUP_ATTEMPTS" ]]; then
          followup_count=$((followup_count + 1))
          echo "   Sending follow-up nudge ($followup_count/$FOLLOWUP_ATTEMPTS)..."
          
          NUDGE="Continue working on the Ralph task. Check RALPH_TASK.md for remaining criteria marked [ ]. Run tests after changes. Say RALPH_COMPLETE when all criteria are satisfied."
          
          send_followup "$agent_id" "$API_KEY" "$NUDGE"
          echo "   ✓ Follow-up sent"
        else
          echo "   Max follow-ups reached. Spawning new agent..."
          
          if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
            echo "⚠️  Max chain depth reached. Stopping."
            exit 1
          fi
          
          NEW_AGENT_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace" 2>&1)
          NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
          
          if [[ -n "$NEW_AGENT_ID" ]]; then
            watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
            exit $?
          else
            echo "❌ Failed to spawn new agent"
            exit 1
          fi
        fi
        ;;
        
      "EXPIRED")
        echo "[$TIMESTAMP] ⏰ Agent expired"
        echo "   Spawning new agent..."
        
        if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
          echo "⚠️  Max chain depth reached. Stopping."
          exit 1
        fi
        
        NEW_AGENT_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace" 2>&1)
        NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
        
        if [[ -n "$NEW_AGENT_ID" ]]; then
          watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
          exit $?
        else
          echo "❌ Failed to spawn new agent"
          exit 1
        fi
        ;;
        
      "ERROR"|"FAILED")
        echo "[$TIMESTAMP] ❌ Agent failed: $STATUS"
        echo "   Summary: $SUMMARY"
        
        # Get conversation to see what went wrong
        CONVERSATION=$(get_agent_conversation "$agent_id" "$API_KEY")
        LAST_MESSAGE=$(echo "$CONVERSATION" | jq -r '.messages[-1].text // "No messages"' | head -c 500)
        echo "   Last message: $LAST_MESSAGE..."
        echo ""
        
        if [[ "$chain_depth" -ge "$MAX_CHAIN_DEPTH" ]]; then
          echo "⚠️  Max chain depth reached. Stopping."
          exit 1
        fi
        
        echo "   Spawning new agent to retry..."
        NEW_AGENT_OUTPUT=$("$SCRIPT_DIR/spawn-cloud-agent.sh" "$workspace" 2>&1)
        NEW_AGENT_ID=$(echo "$NEW_AGENT_OUTPUT" | grep "Agent ID:" | awk '{print $NF}')
        
        if [[ -n "$NEW_AGENT_ID" ]]; then
          watch_agent "$NEW_AGENT_ID" "$workspace" $((chain_depth + 1))
          exit $?
        else
          echo "❌ Failed to spawn new agent"
          exit 1
        fi
        ;;
        
      "CREATING")
        echo "[$TIMESTAMP] 🔧 Agent creating..."
        ;;
        
      *)
        echo "[$TIMESTAMP] ❓ Unknown status: $STATUS"
        ;;
    esac
    
    sleep "$POLL_INTERVAL"
  done
}

# =============================================================================
# ENTRY POINT
# =============================================================================

usage() {
  echo "Usage: $0 <agent-id> [workspace]"
  echo ""
  echo "Watch a Cloud Agent with True Ralph behavior (malloc/free context rotation)."
  echo ""
  echo "Arguments:"
  echo "  agent-id   The Cloud Agent ID (e.g., bc-abc123)"
  echo "  workspace  Path to workspace (default: current directory)"
  echo ""
  echo "Examples:"
  echo "  $0 bc-c1b07cd8-e35a-4366-8d74-d53d16c18bba"
  echo "  $0 bc-abc123 /path/to/project"
  echo ""
  echo "True Ralph Behavior:"
  echo "  1. Poll agent every ${POLL_INTERVAL}s, estimate token usage"
  echo "  2. At ${WARNING_THRESHOLD} tokens: Send wrapup warning (finish file, commit)"
  echo "  3. At ${TOKEN_THRESHOLD} tokens: Force-stop and spawn fresh agent"
  echo "  4. Pass context summary to new agent for continuity"
  echo "  5. Chain up to $MAX_CHAIN_DEPTH agents before giving up"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

AGENT_ID="$1"
WORKSPACE="${2:-.}"

if [[ "$WORKSPACE" == "." ]]; then
  WORKSPACE="$(pwd)"
fi

watch_agent "$AGENT_ID" "$WORKSPACE" 1
