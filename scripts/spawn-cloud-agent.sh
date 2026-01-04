#!/bin/bash
# Ralph Wiggum: Spawn Cloud Agent for True malloc/free
# - Uses EXTERNAL state
# - Commits and pushes local work
# - Spawns Cloud Agent with proper model
# - Updates external progress log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# Get absolute path for workspace
WORKSPACE_ROOT="${1:-.}"
if [[ "$WORKSPACE_ROOT" == "." ]]; then
  WORKSPACE_ROOT="$(pwd)"
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"
CONFIG_FILE="$WORKSPACE_ROOT/.cursor/ralph-config.json"
GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"

# Get external state directory
EXT_DIR=$(get_ralph_external_dir "$WORKSPACE_ROOT")

# =============================================================================
# HELPER FUNCTIONS
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

get_github_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then echo "$GITHUB_TOKEN" && return 0; fi
  if [[ -f "$CONFIG_FILE" ]]; then
    TOKEN=$(jq -r '.github_token // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$TOKEN" ]]; then echo "$TOKEN" && return 0; fi
  fi
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    TOKEN=$(jq -r '.github_token // empty' "$GLOBAL_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$TOKEN" ]]; then echo "$TOKEN" && return 0; fi
  fi
  return 1
}

git_push_with_token() {
  local branch="$1"
  local force="${2:-}"
  
  GH_TOKEN=$(get_github_token) || GH_TOKEN=""
  
  if [[ -n "$GH_TOKEN" ]]; then
    # Use token for authentication
    REPO_URL=$(git remote get-url origin 2>/dev/null)
    # Convert to https with token
    TOKEN_URL=$(echo "$REPO_URL" | sed "s|https://github.com/|https://$GH_TOKEN@github.com/|" | sed "s|git@github.com:|https://$GH_TOKEN@github.com/|")
    if [[ -n "$force" ]]; then
      git push "$TOKEN_URL" "$branch" --force 2>/dev/null
    else
      git push "$TOKEN_URL" "$branch" 2>/dev/null
    fi
  else
    # Fall back to default git push
    if [[ -n "$force" ]]; then
      git push origin "$branch" --force 2>/dev/null
    else
      git push origin "$branch" 2>/dev/null
    fi
  fi
}

get_repo_url() {
  (cd "$WORKSPACE_ROOT" && git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|git@github.com:|https://github.com/|')
}

get_current_branch() {
  (cd "$WORKSPACE_ROOT" && git branch --show-current 2>/dev/null || echo "main")
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  # 1. Check for API key
  API_KEY=$(get_api_key) || {
    echo "❌ Cloud Agent not configured. Get key from https://cursor.com/dashboard?tab=integrations" >&2
    return 1
  }

  # 2. Get repo info
  REPO_URL=$(get_repo_url)
  if [[ -z "$REPO_URL" ]]; then
    echo "❌ Could not determine repository URL. Cloud Agents require GitHub." >&2
    return 1
  fi
  
  CURRENT_BRANCH=$(get_current_branch)
  
  # 3. Commit and Push Local Changes
  cd "$WORKSPACE_ROOT"
  CURRENT_ITERATION=$(get_iteration "$EXT_DIR")
  
  echo "🔄 Checking for local changes..."
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "   Committing and pushing..."
    git add -A
    git commit -m "ralph: iteration $CURRENT_ITERATION checkpoint (cloud handoff)" || true
    
    if ! git_push_with_token "$CURRENT_BRANCH" "force"; then
      echo "⚠️  Could not push. Cloud Agent may not see latest changes." >&2
    fi
  else
    echo "   ✅ Workspace clean."
  fi

  # 4. Calculate next iteration
  NEXT_ITERATION=$((CURRENT_ITERATION + 1))
  NEXT_BRANCH_NAME="ralph-iteration-$NEXT_ITERATION"

  # 5. Build continuation prompt
  # Cloud Agent will read from .ralph/ in the repo (we sync progress there too)
  # Check for context from previous agent (passed via env vars from watch-cloud-agent.sh)
  local context_section=""
  if [[ -n "${RALPH_CONTEXT_SUMMARY:-}" ]]; then
    context_section="
## Context from Previous Agent

The previous agent was stopped due to: ${RALPH_STOP_REASON:-context_limit}

Here's what the previous agent was working on:
${RALPH_CONTEXT_SUMMARY}

Continue from where they left off. Don't repeat work that's already done."
  fi

  CONTINUATION_PROMPT="# Ralph Iteration $NEXT_ITERATION (Cloud Agent - Fresh Context)

You are continuing an autonomous development task using the Ralph methodology.

## CRITICAL: Read State Files First

1. **Task Definition**: Read \`RALPH_TASK.md\` for the task and completion criteria.
2. **Progress**: Read \`.ralph/progress.md\` to see what's been accomplished.
3. **Guardrails**: Read \`.ralph/guardrails.md\` for lessons learned.
${context_section}

## Your Mission

Continue from where iteration $CURRENT_ITERATION left off. That agent's context was full, so you have FRESH CONTEXT.

## Ralph Protocol

1. Read progress.md to understand current state
2. Work on the next unchecked criterion in RALPH_TASK.md
3. Run tests after changes (if test_command is defined)
4. Check off completed criteria with [x]
5. **Commit after each criterion**: \`git add -A && git commit -m 'ralph: [criterion] - description'\`
6. **Push regularly**: \`git push\` after commits
7. **Update progress**: After significant work, update \`.ralph/progress.md\` with what you did
8. When ALL criteria pass: say \`RALPH_COMPLETE\`
9. If stuck 3+ times on same issue: say \`RALPH_GUTTER\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push your changes
3. Update .ralph/progress.md with what you accomplished and what's next
4. You will be rotated to a fresh agent that continues your work

This is normal - it keeps the agent effective by preventing context pollution.

Begin by reading the state files."

  # 6. Use claude-4.5-opus-high-thinking
  echo "🚀 Spawning Cloud Agent for iteration $NEXT_ITERATION..."
  
  SELECTED_MODEL="claude-4.5-opus-high-thinking"
  echo "   Using model: $SELECTED_MODEL"
  
  # 7. Create Cloud Agent
  API_PAYLOAD=$(jq -n \
    --arg prompt "$CONTINUATION_PROMPT" \
    --arg repo "$REPO_URL" \
    --arg ref "$CURRENT_BRANCH" \
    --arg branch "$NEXT_BRANCH_NAME" \
    --arg model "$SELECTED_MODEL" \
    '{
      "prompt": { "text": $prompt },
      "source": {
        "repository": $repo,
        "ref": $ref
      },
      "target": {
        "branchName": $branch,
        "autoCreatePr": false
      },
      "model": $model
    }')

  RESPONSE=$(curl -s -X POST "https://api.cursor.com/v0/agents" \
    -u "$API_KEY:" \
    -H "Content-Type: application/json" \
    -d "$API_PAYLOAD")

  # 8. Handle response
  AGENT_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
  
  if [[ -n "$AGENT_ID" ]]; then
    AGENT_URL=$(echo "$RESPONSE" | jq -r '.target.url // empty')
    
    echo "✅ Cloud Agent spawned!"
    echo "   - Agent ID: $AGENT_ID"
    echo "   - Branch:   $NEXT_BRANCH_NAME"
    echo "   - Monitor:  $AGENT_URL"
    
    # Log to external progress
    cat >> "$EXT_DIR/progress.md" <<-EOF

---

## 🚀 Cloud Agent Handoff

- **Local Iteration**: $CURRENT_ITERATION
- **Cloud Iteration**: $NEXT_ITERATION
- **Agent ID**: $AGENT_ID
- **Branch**: $NEXT_BRANCH_NAME
- **Time**: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Cloud Agent continuing with fresh context.

EOF

    # Also update .ralph/ in workspace so cloud agent can see it
    if [[ -d "$WORKSPACE_ROOT/.ralph" ]]; then
      cp "$EXT_DIR/progress.md" "$WORKSPACE_ROOT/.ralph/progress.md" 2>/dev/null || true
      cp "$EXT_DIR/guardrails.md" "$WORKSPACE_ROOT/.ralph/guardrails.md" 2>/dev/null || true
      
      # Commit the sync
      cd "$WORKSPACE_ROOT"
      git add .ralph/ 2>/dev/null || true
      git commit -m "ralph: sync state for cloud agent iteration $NEXT_ITERATION" 2>/dev/null || true
      git_push_with_token "$CURRENT_BRANCH" "force" || true
    fi
    
    return 0
  else
    ERROR=$(echo "$RESPONSE" | jq -r '.error // .message // "Unknown error"')
    echo "❌ Failed to spawn Cloud Agent: $ERROR" >&2
    return 1
  fi
}

main "$@"
