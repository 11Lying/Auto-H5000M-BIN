#!/bin/sh
# 企业微信群机器人 SMS 转发脚本
API_CONFIG="$1"
[ -z "$API_CONFIG" ] && { echo "Error: no api_config"; exit 1; }
WEBHOOK_URL=$(echo "$API_CONFIG" | jq -r ".webhook_url" 2>/dev/null)
if [ -z "$WEBHOOK_URL" ] || [ "$WEBHOOK_URL" = "null" ]; then
  echo "Error: missing webhook_url"; exit 1
fi

# 去掉发件人前面的 86 国家码(仅当 86 后正好是11位号码时)
SENDER="$SMS_SENDER"
case "$SENDER" in
  86*)
    rest="${SENDER#86}"
    case "$rest" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) SENDER="$rest" ;;
    esac ;;
esac

CONTENT=$(printf "发件人: %s\n时间: %s\n内容: %s" "$SENDER" "$SMS_TIME" "$SMS_CONTENT")
# 用 jq 安全构造 JSON(自动转义引号/换行/反斜杠)
PAYLOAD=$(jq -n --arg c "$CONTENT" "{msgtype:\"text\",text:{content:\$c}}")
RESP=$(curl -s -m 15 -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "$RESP"
case "$RESP" in
  *"\"errcode\":0"*) exit 0 ;;
  *) exit 1 ;;
esac
