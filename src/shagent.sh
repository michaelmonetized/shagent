#!/usr/bin/env zsh

# ==============================================================================
# 1. Error Handling, Usage Printing & Clean Exit Traps
# ==============================================================================
# Beautiful clean printout explaining script arguments
print_usage() {
    cat << EOF
Usage: shagent [OPTIONS] "YOUR TASK DESCRIPTION"

An agentic AI harness running natively inside your customized Zsh profile.

Options:
  -s, --session <name>   Resume or isolate an ongoing conversation state.
                         (Default session name is: 'default')
  -h, --help             Display this help directory overview and exit.

Environment Variables (Checked in ~/.zshenv, ~/.zshrc, or local .env):
  OPENROUTER_API_KEY     Required API key to hit OpenRouter endpoint.
  SHAGENT_MODEL          OpenRouter model slug. Defaults to 'openrouter/free'.
EOF
}

# Cleanup utility hook to purge runtime cache
cleanup() {
    [[ -n "$CONTEXT_FILE" && -f "$CONTEXT_FILE" ]] && rm -f "$CONTEXT_FILE"
}
trap cleanup EXIT INT TERM

# ==============================================================================
# 2. Native Zsh Environment Bootstrapping Pipeline
# ==============================================================================
# Source environment files BEFORE setting -e, as they often contain non-zero returns.
# We use an anonymous function to clear positional parameters during sourcing
# to prevent sourced scripts from misinterpreting shagent's arguments.
() {
    [[ -f "$HOME/.zshenv" ]] && source "$HOME/.zshenv"
    [[ -f "$HOME/.zprofile" ]] && source "$HOME/.zprofile"
    [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc"
}

set -e # Exit immediately if a pipeline fails unexpectedly

if [[ -f .env ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^# ]] || [[ -z "${line//[[:space:]]/}" ]] && continue
        # Prevent injection vulnerabilities by verifying valid assignment format
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            export "$line"
        fi
    done < .env
fi

export OPENROUTER_API_KEY="${OPENROUTER_API_KEY}"
export SHAGENT_MODEL="${SHAGENT_MODEL:-openrouter/free}"

# ==============================================================================
# 3. Argument Validation & Flag Checking
# ==============================================================================
SESSION_NAME="default"

while (( $# > 0 )); do
    case "$1" in
        -h|--help)
            print_usage
            exit 0
            ;;
        -s|--session)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo -e "\033[1;31mError: --session requires a valid non-empty argument.\033[0m\n" >&2
                print_usage
                exit 1
            fi
            SESSION_NAME="$2"
            shift 2
            ;;
        *)
            # Break on the first element that is not a recognized flag option
            break
            ;;
    esac
done

USER_TASK="$*"

if [[ -z "$OPENROUTER_API_KEY" ]]; then
    echo -e "\033[1;31mError: OPENROUTER_API_KEY could not be found.\033[0m" >&2
    echo "Please declare it in ~/.zshenv, ~/.zshrc, or your local workspace .env file." >&2
    exit 1
fi

# Determine persistence path structures
MEMORY_DIR="$HOME/.shagent/memory"
mkdir -p "$MEMORY_DIR"

JSONL_STATE="$MEMORY_DIR/${SESSION_NAME}.jsonl"
MARKDOWN_MEMORY="$MEMORY_DIR/${SESSION_NAME}.md"

touch "$JSONL_STATE" "$MARKDOWN_MEMORY"

# ==============================================================================
# 4. Fast Native Dependency Checks
# ==============================================================================
local -a deps
deps=(rg fd eza bat git jq curl sed awk tr cat echo qmd mcp-cli)
for cmd in $deps; do
    if ! (( $+commands[$cmd] )); then
        echo -e "\033[1;33mWarning:\033[0m Optional tool '$cmd' was not found in your current path configuration." >&2
    fi
done

# ==============================================================================
# 5. Agentic Prompt & Constraint Definition
# ==============================================================================
INITIAL_SYSTEM_PROMPT=$(cat << 'EOF'
You are shagent, an AI agent operating natively in the user's Zsh shell session.
You leverage modern shell utilities and custom integrations directly inside the workspace.

CORE SYSTEM UTILITIES:
- Content Matching: rg <pattern>
- File Discovery: fd <pattern>
- Directory Browsing: eza -la
- Inspector/Viewer: bat --style=numbers <file>
- Safe Modification Isolation: git worktree / git branch

CORE BUILTINS:
- Use standard utilities (sed, awk, tr, cat, echo, etc.) for text manipulation and normal operations.

LOCAL TOOL EXTENSIONS:
1. Chrome Web Browsing (via local Chrome DevTools MCP):
   Run: mcp-cli call chrome-devtools-mcp search_web '{"query": "your query"}'
2. Long-term Session Memory Search (via qmd local vector database):
   Run: qmd search -c shagent "your query"

RESPONSE INTERFACE CONSTRAINT:
You must respond strictly using this layout. Avoid any text wrapper blocks outside this structure:

THOUGHT: Analyze context, previous output, or evaluate memory queries.
COMMAND: Native shell code line or tool extension line to execute.

If your task is complete or you have successfully derived an answer, exit using:
THOUGHT: Task finished.
COMMAND: echo "Task complete!"
EOF
)

# ==============================================================================
# 6. Session State Restoration & Initialization
# ==============================================================================
CONTEXT_FILE=$(mktemp /tmp/shagent_ctx.XXXXXX)

if [[ -s "$JSONL_STATE" ]]; then
    jq -s --arg r "system" --arg c "$INITIAL_SYSTEM_PROMPT" \
      'if .[0].role == "system" then . else [{role: $r, content: $c}] + . end' \
      "$JSONL_STATE" > "$CONTEXT_FILE"
    echo -e "\033[1;32m-> Resumed ongoing session trace context: '$SESSION_NAME'\033[0m"
else
    jq -n --arg r "system" --arg c "$INITIAL_SYSTEM_PROMPT" '[{role: $r, content: $c}]' > "$CONTEXT_FILE"
fi

append_state() {
    local role="$1"
    local content="$2"
    
    local tmp=$(mktemp)
    jq --arg r "$role" --arg c "$content" '. += [{"role": $r, "content": $c}]' "$CONTEXT_FILE" > "$tmp"
    mv "$tmp" "$CONTEXT_FILE"
    
    jq -n --arg r "$role" --arg c "$content" '{role: $r, content: $c}' >> "$JSONL_STATE"
}

# Capture or request user target goal if history is clean
if [[ -n "$USER_TASK" ]]; then
    append_state "user" "$USER_TASK"
elif [[ ! -s "$JSONL_STATE" ]]; then
    echo -n "What can shagent execute for you? "
    read -r USER_TASK
    if [[ -z "$USER_TASK" ]]; then
        echo "No task provided. Exiting."
        exit 0
    fi
    append_state "user" "$USER_TASK"
fi

# ==============================================================================
# 7. ReAct Agent Engine Execution Loop
# ==============================================================================
echo "shagent running | Session: $SESSION_NAME | Model Target: $SHAGENT_MODEL"

while true; do
    # Call OpenRouter API safely
    local request_body
    request_body=$(jq -n \
        --arg model "$SHAGENT_MODEL" \
        --argjson messages "$(cat "$CONTEXT_FILE")" \
        '{model: $model, messages: $messages}')

    RESPONSE=$(curl -s -w "\n%{http_code}" https://openrouter.ai/api/v1/chat/completions \
        -H "Authorization: Bearer $OPENROUTER_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$request_body")

    # Separate standard response output payload text block from HTTP status code
    HTTP_STATUS=$(printf "%s" "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(printf "%s" "$RESPONSE" | sed '$d')

    if [[ "$HTTP_STATUS" -ne 200 ]]; then
        echo -e "\n\033[1;31mOpenRouter API Request Failed (HTTP $HTTP_STATUS):\033[0m" >&2
        printf "Response body (raw):\n%s\n" "$RESPONSE_BODY" | cat -A >&2
        printf "%s" "$RESPONSE_BODY" | jq -r '.error.message // "Unknown error content encountered."' >&2
        exit 1
    fi

    AI_RESPONSE=$(printf "%s" "$RESPONSE_BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo "null")
    
    if [[ -z "$AI_RESPONSE" || "$AI_RESPONSE" == "null" ]]; then
        echo -e "\n\033[1;31mError: Received invalid message body response structure from OpenRouter.\033[0m" >&2
        exit 1
    fi

    # Dissect structured text layout
    THOUGHT=$(echo "$AI_RESPONSE" | sed -n 's/^THOUGHT: //p')
    COMMAND=$(echo "$AI_RESPONSE" | sed -n 's/^COMMAND: //p')

    if [[ -n "$THOUGHT" ]]; then
        echo -e "\n\033[1;34m[shagent Thought]:\033[0m $THOUGHT"
    fi

    if [[ "$THOUGHT" == *"Task finished."* || -z "$COMMAND" ]]; then
        echo -e "\033[1;32mExecution pipeline complete.\033[0m\n"
        break
    fi

    echo -e "\033[1;33m[Executing]:\033[0m $COMMAND"
    
    # Run evaluated action line within the native terminal profile space
    set +e # Turn off instant termination to capture tool errors gracefully
    COMMAND_OUTPUT=$(eval "$COMMAND" 2>&1)
    set -e # Reactivate safety flag constraint
    
    if [[ -z "$COMMAND_OUTPUT" ]]; then
        COMMAND_OUTPUT="Command successfully evaluated with no output messages returned."
    fi

    append_state "assistant" "$AI_RESPONSE"
    append_state "user" "COMMAND OUTPUT:\n$COMMAND_OUTPUT"

    # ==============================================================================
    # 8. Post-Turn Global qmd Collection Synchronization
    # ==============================================================================
    echo -e "\n### Turn Event: $(date)\n* **Thought**: $THOUGHT\n* **Executed**: \`$COMMAND\`\n* **Result Snippet**:\n\`\`\`text\n${COMMAND_OUTPUT:0:1000}\n\`\`\`" >> "$MARKDOWN_MEMORY"
    
    # Run qmd vector actions asynchronously if the binary exists to maintain prompt speed
    if (( $+commands[qmd] )); then
        (qmd update &>/dev/null && qmd embed &>/dev/null) &!
    fi
done

