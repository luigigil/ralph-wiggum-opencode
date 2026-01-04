#!/bin/bash
# Ralph Wiggum: Spawn Cloud Agent for True malloc/free
# This script ensures local work is committed and pushed, then spawns a new Cloud Agent.

set -euo pipefail

WORKSPACE_ROOT="${1:-.}"
RALPH_DIR="$WORKSPACE_ROOT/.ralph"
STATE_FILE="$RALPH_DIR/state.md"
CONFIG_FILE="$WORKSPACE_ROOT/.cursor/ralph-config.json"
GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"

# --- Helper Functions ---

# Get API key from config or environment
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

# Get repository URL from git
get_repo_url() {
  (cd "$WORKSPACE_ROOT" && git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|git@github.com:|https://github.com/|')
}

# Get current branch, default to main
get_current_branch() {
  (cd "$WORKSPACE_ROOT" && git branch --show-current 2>/dev/null || echo "main")
}

# --- Main Execution ---

main() {
  # 1. Check for API key
  API_KEY=$(get_api_key) || {
    echo "❌ Cloud Agent integration not configured. Get key from https://cursor.com/dashboard?tab=integrations" >&2
    echo "Configure via CURSOR_API_KEY, .cursor/ralph-config.json, or ~/.cursor/ralph-config.json" >&2
    return 1
  }

  # 2. Get repo info
  REPO_URL=$(get_repo_url)
  if [[ -z "$REPO_URL" ]]; then
    echo "❌ Could not determine repository URL. Cloud Agents require a GitHub repository." >&2
    return 1
  fi
  
  CURRENT_BRANCH=$(get_current_branch)
  
  # 3. Commit and Push Local Changes (CRITICAL STEP)
  cd "$WORKSPACE_ROOT"
  echo "🔄 Checking for local changes to commit before handoff..."
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "   Found changes. Committing and pushing..."
    git add -A
    CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" 2>/dev/null | sed 's/iteration: *//' || echo "0")
    git commit -m "Ralph iteration $CURRENT_ITERATION checkpoint (before cloud handoff)"
    
    # Force push to ensure the cloud agent gets the latest state, even if history was rewritten
    if git push origin "$CURRENT_BRANCH" --force; then
      echo "   ✅ Pushed changes to $CURRENT_BRANCH."
    else
      echo "❌ CRITICAL: Could not push to remote branch '$CURRENT_BRANCH'." >&2
      echo "   The Cloud Agent will NOT see your latest changes. Aborting." >&2
      echo "   Please resolve the git push issue manually and re-run." >&2
      return 1
    fi
  else
    echo "   ✅ No local changes to commit. Workspace is clean."
  fi

  # 4. Calculate Iteration
  CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" 2>/dev/null | sed 's/iteration: *//' || echo "0")
  NEXT_ITERATION=$((CURRENT_ITERATION + 1))
  NEXT_BRANCH_NAME="ralph-iteration-$NEXT_ITERATION"

  # 5. Build the Continuation Prompt
  CONTINUATION_PROMPT=$(cat <<-EOF
# Ralph Iteration $NEXT_ITERATION (Cloud Agent - Fresh Context)

You are continuing an autonomous development task using the Ralph Wiggum methodology.

## CRITICAL: Read State Files First

1.  **Task Definition**: Read `RALPH_TASK.md` for the full task and completion criteria.
2.  **Progress**: Read `.ralph/progress.md` to see what has been accomplished.
3.  **Guardrails**: Read `.ralph/guardrails.md` for lessons learned from past failures.

## Your Mission

Continue from where the previous iteration left off. The local agent's context was full (malloc limit reached), so you have been spawned with FRESH CONTEXT.

## Ralph Protocol

1.  Analyze `progress.md` to determine the next step.
2.  Execute the NEXT incomplete item from `RALPH_TASK.md`.
3.  Update `.ralph/progress.md` with your accomplishments.
4.  Commit changes to the current branch (`$NEXT_BRANCH_NAME`).
5.  If ALL criteria are met, add `RALPH_COMPLETE: All criteria satisfied` to progress.md.
6.  If stuck after 3+ attempts, add `RALPH_GUTTER: Need human intervention`.

Begin by reading the state files.
EOF
)

  # 6. Create the Cloud Agent via Cursor API
  echo "🚀 Spawning Cloud Agent for iteration $NEXT_ITERATION..."
  
  API_PAYLOAD=$(jq -n \
    --arg prompt "$CONTINUATION_PROMPT" \
    --arg repo "$REPO_URL" \
    --arg ref "$CURRENT_BRANCH" \
    --arg branch "$NEXT_BRANCH_NAME" \
    '{
      "prompt": { "text": $prompt },
      "source": {
        "repository": $repo,
        "ref": $ref
      },
      "target": {
        "branchName": $branch,
        "autoCreatePr": false
      }
    }')

  RESPONSE=$(curl -s -X POST "https://api.cursor.com/v0/agents" \
    -u "$API_KEY:" \
    -H "Content-Type: application/json" \
    -d "$API_PAYLOAD")

  # 7. Handle API Response
  AGENT_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
  
  if [[ -n "$AGENT_ID" ]]; then
    AGENT_URL=$(echo "$RESPONSE" | jq -r '.target.url // empty')
    
    echo "✅ Cloud Agent spawned successfully!"
    echo "   - Agent ID: $AGENT_ID"
    echo "   - Branch:   $NEXT_BRANCH_NAME"
    echo "   - Monitor:  $AGENT_URL"
    echo "The Cloud Agent is now working with FRESH CONTEXT. Your local context has been freed."
    
    # Log the handoff to progress.md
    cat >> "$RALPH_DIR/progress.md" <<-EOF

---

## 🚀 Cloud Agent Handoff

-   **Local Iteration**: $CURRENT_ITERATION
-   **Cloud Iteration**: $NEXT_ITERATION
-   **Agent ID**: $AGENT_ID
-   **Branch**: $NEXT_BRANCH_NAME
-   **Reason**: Context malloc limit reached
-   **Time**: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Context has been freed. Cloud Agent continuing with fresh context.

EOF
    return 0
  else
    ERROR=$(echo "$RESPONSE" | jq -r '.error // .message // "Unknown error"')
    echo "❌ Failed to spawn Cloud Agent: $ERROR" >&2
    echo "Falling back to Local Mode. Please start a new conversation manually." >&2
    return 1
  fi
}

main "$@"
