FROM public.ecr.aws/lambda/python:3.12-arm64

ARG PIXLET_VERSION=0.34.0

# Pixlet links against libwebp at runtime.
RUN dnf install -y libwebp libwebp-tools tar gzip && dnf clean all

RUN curl -fsSL -o /tmp/pixlet.tgz \
      "https://github.com/tidbyt/pixlet/releases/download/v${PIXLET_VERSION}/pixlet_${PIXLET_VERSION}_linux_arm64.tar.gz" \
 && tar -xzf /tmp/pixlet.tgz -C /usr/local/bin pixlet \
 && rm /tmp/pixlet.tgz \
 && pixlet version

# Build context is the project root (see deploy.sh).
COPY lambda/handler.py apps.json ${LAMBDA_TASK_ROOT}/
COPY apps/ ${LAMBDA_TASK_ROOT}/apps/

CMD ["handler.lambda_handler"]
