#!/bin/sh
set -eu
DEST="/var/mobile/Media/HeadsetBridge-export-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
COUNT=0
for NAME in HeadsetBridge-springboard.jsonl HeadsetBridge-springboard.jsonl.previous; do
 FILE="/var/mobile/Library/Logs/$NAME"
 if [ -f "$FILE" ]; then cp "$FILE" "$DEST/"; COUNT=$((COUNT + 1)); fi
done
for DIR in /var/mobile/Containers/Data/Application/*; do
 for NAME in HeadsetBridge-music.jsonl HeadsetBridge-music.jsonl.previous; do
  if [ -f "$DIR/Documents/$NAME" ]; then
   BASE=$(basename "$DIR")
   cp "$DIR/Documents/$NAME" "$DEST/${BASE}-${NAME}"
   COUNT=$((COUNT + 1))
  fi
 done
done
echo "Copied $COUNT HeadsetBridge files to: $DEST"
echo 'Only merged-plugin logs copied. No old plugin configs or app account data collected.'
