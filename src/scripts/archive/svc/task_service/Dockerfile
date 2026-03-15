# syntax=docker/dockerfile:1.5
####################################################################
# Multi-stage production Dockerfile for Task Service
# - builder stage: compile wheels for native deps (no compilers in runtime)
# - runtime stage: minimal image with tini, libpq5, ca-certificates
# - deterministic non-root user, ownership, healthcheck aligned to /health
# - run uvicorn as single-process (scale with k8s replicas)
####################################################################
ARG PYTHON_IMAGE=python:3.13.12-slim
FROM ${PYTHON_IMAGE} AS builder

ARG DEBIAN_FRONTEND=noninteractive
WORKDIR /build

# Build-time dependencies for native extensions (asyncpg, cryptography, pydantic-core, etc.)
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

# Copy only requirements first to maximize cache reuse
COPY src/services/common/requirements.txt /build/common-requirements.txt
COPY src/services/task_service/requirements.txt /build/requirements.txt

# Merge service + common requirements into one deterministic file
RUN set -eux; \
    if [ -s /build/common-requirements.txt ]; then \
        cat /build/common-requirements.txt /build/requirements.txt > /build/merged-requirements.txt; \
    else \
        cp /build/requirements.txt /build/merged-requirements.txt; \
    fi

# Build wheels for everything into /wheels (faster, deterministic installs at runtime)
RUN python -m pip install --upgrade pip setuptools wheel && \
    python -m pip wheel --wheel-dir=/wheels -r /build/merged-requirements.txt

####################################################################
FROM ${PYTHON_IMAGE} AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG APP_USER=app
ARG APP_UID=10001
ARG APP_GID=10001
ARG APP_PORT=8003

WORKDIR /app

# Minimal runtime dependencies: libpq5 for asyncpg, tini for PID1 handling
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      libpq5 \
      tini \
    && rm -rf /var/lib/apt/lists/*

# Create deterministic unprivileged user/group early (so COPY --chown works)
RUN groupadd -g ${APP_GID} ${APP_USER} || true && \
    useradd --uid ${APP_UID} --gid ${APP_GID} --create-home --home-dir /home/${APP_USER} --shell /usr/sbin/nologin ${APP_USER}

# Copy built wheels & merged requirements from builder
COPY --from=builder /wheels /wheels
COPY --from=builder /build/merged-requirements.txt /app/merged-requirements.txt

# Install python packages using prebuilt wheels (fallback to PyPI for any missing)
RUN python -m pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir --find-links=/wheels -r /app/merged-requirements.txt && \
    pip cache purge

# Copy application source; use --chown when available to avoid extra chown layer (requires BuildKit)
COPY --chown=${APP_UID}:${APP_GID} src /app/src
RUN chown -R ${APP_UID}:${APP_GID} /app && chmod -R a+rX /app

# Runtime environment defaults
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    LOG_LEVEL=INFO \
    SERVICE_NAME=task \
    PYTHONPATH=/app \
    PORT=${APP_PORT}

EXPOSE ${APP_PORT}

# Healthcheck: call the application's /health endpoint on configured port
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys,os; p=os.getenv('PORT','8003'); req=urllib.request.Request('http://127.0.0.1:'+p+'/health'); \
try: r=urllib.request.urlopen(req, timeout=4); sys.exit(0 if r.getcode()==200 else 1) \
except Exception: sys.exit(1)"

# Use tini as PID 1 to forward signals and reap children
ENTRYPOINT ["/usr/bin/tini", "--"]

# Run as unprivileged user
USER ${APP_UID}:${APP_GID}

# Default command: single-process Uvicorn. Scale horizontally via k8s replicas.
CMD ["uvicorn", "src.services.task_service.app:app", "--host", "0.0.0.0", "--port", "8003", "--loop", "asyncio", "--limit-concurrency", "100", "--log-level", "info"]