#!/bin/bash
# check-messages.sh — Inject new intercom messages into Claude's context
# Runs on UserPromptSubmit. Only active if any subscription exists in the DB.
# Cycles through all subscribed names and delivers new messages.

DB="/Users/tavy/Documents/white_tree/intercom/intercom.db"

[ -f "$DB" ] || exit 0

# Get all subscriptions with pending messages
SUBS=$(sqlite3 "$DB" "
    SELECT s.name, s.last_seen_id
    FROM subscriptions s
    WHERE EXISTS (SELECT 1 FROM messages m WHERE m.id > s.last_seen_id)
" 2>/dev/null)

[ -z "$SUBS" ] && exit 0

# Collect new messages across all subscriptions (use lowest last_seen_id)
MIN_ID=$(sqlite3 "$DB" "SELECT MIN(last_seen_id) FROM subscriptions" 2>/dev/null)

NEW_MESSAGES=$(sqlite3 -separator $'\n' "$DB" "
    SELECT '#' || id || ' [' || created_at || '] ' || sender ||
           CASE WHEN type != 'chat' THEN ' [' || type || ']' ELSE '' END ||
           CASE WHEN reply_to IS NOT NULL THEN ' (re: #' || reply_to || ')' ELSE '' END ||
           ': ' || content
    FROM messages
    WHERE id > $MIN_ID
    ORDER BY id
" 2>/dev/null)

[ -z "$NEW_MESSAGES" ] && exit 0

# Update all subscriptions to current max
sqlite3 "$DB" "
    UPDATE subscriptions
    SET last_seen_id = (SELECT COALESCE(MAX(id), 0) FROM messages)
    WHERE last_seen_id < (SELECT COALESCE(MAX(id), 0) FROM messages)
" 2>/dev/null

COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages WHERE id > $MIN_ID" 2>/dev/null)

# Escape for JSON
ESCAPED=$(echo "$NEW_MESSAGES" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" | sed 's/^"//;s/"$//')

echo "{\"hookSpecificOutput\": {\"hookEventName\": \"UserPromptSubmit\", \"additionalContext\": \"[Intercom: ${COUNT} new message(s)]\\n${ESCAPED}\"}}"
