#!/bin/bash
# check-messages.sh — Inject new intercom messages into Claude's context
# Runs on UserPromptSubmit. Only active if a subscription exists in the DB.
# Each instance tracks its own cursor via a per-PID temp file.

DB="/Users/tavy/Documents/white_tree/intercom/intercom.db"

[ -f "$DB" ] || exit 0

# Check if any subscription exists (opt-in check)
HAS_SUB=$(sqlite3 "$DB" "SELECT COUNT(*) FROM subscriptions" 2>/dev/null)
[ "$HAS_SUB" = "0" ] && exit 0

# Per-instance cursor file (PPID = the claude process)
CURSOR_FILE="/tmp/intercom-cursor-$PPID"

if [ ! -f "$CURSOR_FILE" ]; then
    # First run: seed from the subscription's last_seen_id (use max across all subs)
    SEED=$(sqlite3 "$DB" "SELECT COALESCE(MAX(last_seen_id), 0) FROM subscriptions" 2>/dev/null)
    echo "$SEED" > "$CURSOR_FILE"
    exit 0
fi

LAST_ID=$(cat "$CURSOR_FILE" 2>/dev/null || echo "0")

# Check for new messages
NEW_MESSAGES=$(sqlite3 -separator $'\n' "$DB" "
    SELECT '#' || id || ' [' || created_at || '] ' || sender ||
           CASE WHEN type != 'chat' THEN ' [' || type || ']' ELSE '' END ||
           CASE WHEN reply_to IS NOT NULL THEN ' (re: #' || reply_to || ')' ELSE '' END ||
           ': ' || content
    FROM messages
    WHERE id > $LAST_ID
    ORDER BY id
" 2>/dev/null)

[ -z "$NEW_MESSAGES" ] && exit 0

# Update cursor (only this instance's file, not the DB)
sqlite3 "$DB" "SELECT COALESCE(MAX(id), 0) FROM messages" > "$CURSOR_FILE" 2>/dev/null

COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages WHERE id > $LAST_ID" 2>/dev/null)

# Escape for JSON
ESCAPED=$(echo "$NEW_MESSAGES" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" | sed 's/^"//;s/"$//')

echo "{\"hookSpecificOutput\": {\"hookEventName\": \"UserPromptSubmit\", \"additionalContext\": \"[Intercom: ${COUNT} new message(s)]\\n${ESCAPED}\"}}"
