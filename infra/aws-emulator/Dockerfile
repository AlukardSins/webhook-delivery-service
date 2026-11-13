# AWS Emulator for local SQS (ADR-0005).
# Based on the Dockerfile in AWS's "Getting started with Docker" guide, with two
# changes: it installs a pinned version instead of LTS/latest, and it verifies
# the package's GPG signature before installing it.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal

# 1.0.345 is commit 1874aea, the release the ADR-0005 fidelity scores were
# measured on. Re-check the scores before bumping it.
# Versions: https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/versions.json
ARG EMULATOR_VERSION=1.0.345
# x86_64, or aarch64 on Arm and Apple silicon.
ARG EMULATOR_ARCH=x86_64
ARG PACKAGES_URL=https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS
# AWS publishing key fingerprint, as published in the emulator user guide.
ARG SIGNING_KEY_FINGERPRINT=98BCF336A3BE53B734E967C52E5BF49BD940F624

ADD ${PACKAGES_URL}/aws-emulator-${EMULATOR_VERSION}-1-${EMULATOR_ARCH}.rpm /tmp/aws-emulator.rpm
ADD ${PACKAGES_URL}/aws-emulator-${EMULATOR_VERSION}-1-${EMULATOR_ARCH}.rpm.sig /tmp/aws-emulator.rpm.sig
ADD https://downloads.aws.com/keys/gpg/current.asc /tmp/signing-key.asc

# AWS publishes GPG signatures, not checksums. VALIDSIG must name the pinned
# fingerprint, so a signature from any other key in current.asc is rejected.
# --import exits 2 here because the minimal image has no gpg-agent, even though
# the public key is imported; the VALIDSIG check is the gate.
RUN export GNUPGHOME="$(mktemp -d)" \
    && { gpg --batch --quiet --import /tmp/signing-key.asc 2>/dev/null || true; } \
    && gpg --batch --status-fd 1 --verify /tmp/aws-emulator.rpm.sig /tmp/aws-emulator.rpm \
       | grep -q "VALIDSIG .*${SIGNING_KEY_FINGERPRINT}" \
    && rpm -i /tmp/aws-emulator.rpm \
    && rm -rf "$GNUPGHOME" /tmp/aws-emulator.rpm /tmp/aws-emulator.rpm.sig /tmp/signing-key.asc \
    && mkdir -p /home/emulator && chown 1000 /home/emulator

USER 1000
ENV HOME=/home/emulator
EXPOSE 9297
ENTRYPOINT ["aws-emulator", "-b", "0.0.0.0"]
