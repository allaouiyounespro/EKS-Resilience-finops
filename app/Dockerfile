# witness app image
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
#   docker build -t <registry>/witness:0.1.0 app/
#   docker push  <registry>/witness:0.1.0
#
# Then set image: in k8s/workload/deployment.yaml, or let
# scripts/bootstrap-cluster.sh substitute WITNESS_IMAGE for you.

FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

# Non-root. The pod's securityContext enforces this too, but an image that only
# works as root would make that enforcement a deploy-time failure instead of a
# build-time one.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin witness
USER 10001

EXPOSE 8080

ENTRYPOINT ["./entrypoint.sh"]
