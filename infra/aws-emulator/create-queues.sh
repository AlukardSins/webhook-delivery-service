#!/bin/sh
# Creates the SQS queues from ADR-0002 in the AWS Emulator.
# The emulator keeps state in memory, so this runs on every `docker compose up`
# and `docker compose restart`. CreateQueue with the same name and attributes
# returns the existing queue, so running it twice is safe.
#
# --no-verify-ssl: the emulator's certificate only names localhost and
# 127.0.0.1, and this container reaches it as aws-emulator. The traffic stays
# on the local Compose network, and the keys are valid only for this emulator
# run. The app on the host does verify the certificate (NODE_EXTRA_CA_CERTS).
set -eu

sqs() { aws --no-verify-ssl sqs "$@"; }

# `docker compose restart` doesn't wait for the emulator's healthcheck, and
# each emulator start writes new credentials, so wait until a call succeeds.
attempts=0
until sqs list-queues > /dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 30 ]; then
    echo "AWS Emulator not reachable after 30 attempts" >&2
    sqs list-queues
    exit 1
  fi
  sleep 1
done

dlq_url=$(sqs create-queue --queue-name "$SQS_DLQ_NAME" --query QueueUrl --output text)
dlq_arn=$(sqs get-queue-attributes --queue-url "$dlq_url" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

cat > /tmp/queue-attributes.json <<EOF
{
  "VisibilityTimeout": "$SQS_VISIBILITY_TIMEOUT_SECONDS",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"$dlq_arn\",\"maxReceiveCount\":\"$SQS_MAX_RECEIVE_COUNT\"}"
}
EOF

queue_url=$(sqs create-queue --queue-name "$SQS_QUEUE_NAME" \
  --attributes file:///tmp/queue-attributes.json --query QueueUrl --output text)

echo "ready: $queue_url (DLQ: $dlq_url)"
