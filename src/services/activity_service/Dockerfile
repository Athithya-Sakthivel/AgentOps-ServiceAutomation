# syntax=docker/dockerfile:1.5
####################################################################
# Multi-stage production Dockerfile for Activity Service
# - builds binary wheels in a builder stage (no compilers in runtime)
# - minimal runtime image with tini, libpq5, ca-certificates
# - deterministic non-root user, proper ownership, healthcheck aligned to /health
# - uvicorn run configuration suitable for k8s (single process / worker)
####################################################################
ARG PYTHON_IMAGE=python:3.13.12-slim
FROM ${PYTHON_IMAGE} AS builder

ARG DEBIAN_FRONTEND=noninteractive
WORKDIR /build

# Install build-time dependencies for native extensions (asyncpg, cryptography, pydantic-core, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      gcc \
      g++ \
      libpq-dev \
      libssl-dev \
      pkg-config \
      ca-certificates \
      curl \
      rustc \
      cargo \
    && rm -rf /var/lib/apt/lists/*

# Copy only requirements first to leverage cache
COPY src/services/common/requirements.txt /build/common-requirements.txt
COPY src/services/activity_service/requirements.txt /build/requirements.txt

# Merge service + common requirements into a single deterministic file
RUN set -eux; \
    if [ -s /build/common-requirements.txt ]; then \
        cat /build/common-requirements.txt /build/requirements.txt > /build/merged-requirements.txt; \
    else \
        cp /build/requirements.txt /build/merged-requirements.txt; \
    fi

# Build wheels for all requirements into /wheels (prebuilt binary artifacts)
RUN python -m pip install --upgrade pip setuptools wheel && \
    python -m pip wheel --wheel-dir=/wheels -r /build/merged-requirements.txt

####################################################################
FROM ${PYTHON_IMAGE} AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG APP_USER=app
ARG APP_UID=10001
ARG APP_GID=10001
ARG APP_PORT=8002

WORKDIR /app

# Minimal runtime deps: libpq5 for asyncpg, ca-certificates, tini for PID1
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      libpq5 \
      tini \
    && rm -rf /var/lib/apt/lists/*

# Create unprivileged user/group early so COPY --chown works (BuildKit recommended)
RUN groupadd -g ${APP_GID} ${APP_USER} || true && \
    useradd --uid ${APP_UID} --gid ${APP_GID} --create-home --home-dir /home/${APP_USER} --shell /usr/sbin/nologin ${APP_USER}

# Copy wheels & merged requirements from builder
COPY --from=builder /wheels /wheels
COPY --from=builder /build/merged-requirements.txt /app/merged-requirements.txt

# Install python packages using the prebuilt wheels first
RUN python -m pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir --find-links=/wheels -r /app/merged-requirements.txt && \
    pip cache purge

# Copy application source and ensure correct ownership/permissions
# Use --chown when available (BuildKit) to avoid extra chown layer
COPY --chown=${APP_UID}:${APP_GID} src /app/src
RUN chown -R ${APP_UID}:${APP_GID} /app && chmod -R a+rX /app

# Runtime environment
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    LOG_LEVEL=INFO \
    SERVICE_NAME=activity \
    PYTHONPATH=/app \
    APP_PORT=${APP_PORT}

EXPOSE ${APP_PORT}

# Healthcheck: points to the activity service /health endpoint (returns 200 when process alive)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys,os; p=os.getenv('APP_PORT','8002'); req=urllib.request.Request('http://127.0.0.1:'+p+'/health'); \
try: r=urllib.request.urlopen(req, timeout=4); sys.exit(0 if r.getcode()==200 else 1) \
except Exception: sys.exit(1)"

# Use tini as PID 1 to forward signals and reap children
ENTRYPOINT ["/usr/bin/tini", "--"]

# Run as unprivileged user
USER ${APP_UID}:${APP_GID}

# Default command: single-process Uvicorn (scale horizontally via k8s replicas)
CMD ["uvicorn", "src.services.activity_service.app:app", "--host", "0.0.0.0", "--port", "8002", "--loop", "asyncio", "--limit-concurrency", "100", "--log-level", "info"]