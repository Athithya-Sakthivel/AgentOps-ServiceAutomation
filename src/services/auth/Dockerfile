# syntax=docker/dockerfile:1.5
################################################################################
# Stage: builder
# - installs build deps (gcc, rust/cargo, libpq-dev, libssl-dev, etc.)
# - builds wheels for all requirements into /wheels
################################################################################
ARG PYTHON_IMAGE=python:3.13.12-slim
FROM ${PYTHON_IMAGE} AS builder

ARG DEBIAN_FRONTEND=noninteractive
WORKDIR /build

# Install build-time packages (kept only in builder)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      gcc \
      g++ \
      libpq-dev \
      libssl-dev \
      pkg-config \
      ca-certificates \
      curl \
      rustc \
      cargo && \
    rm -rf /var/lib/apt/lists/*

# Copy only dependency files first to leverage Docker layer cache
# Adjust paths to match your repo layout if needed
COPY src/services/common/requirements.txt /build/common-requirements.txt
COPY src/services/auth/requirements.txt  /build/requirements.txt

# Merge requirements (keeps a single file for wheel build)
RUN set -eux; \
    if [ -s /build/common-requirements.txt ]; then \
        cat /build/common-requirements.txt /build/requirements.txt > /build/merged-requirements.txt; \
    else \
        cp /build/requirements.txt /build/merged-requirements.txt; \
    fi

# Build wheels for all requirements into /wheels (faster runtime installs, no compilers)
RUN python -m pip install --upgrade pip setuptools wheel && \
    python -m pip wheel --wheel-dir=/wheels -r /build/merged-requirements.txt

################################################################################
# Stage: runtime
# - minimal runtime libs only
# - installs python packages from wheels (and falls back to PyPI if a wheel is missing)
# - creates an unprivileged user and ensures /app ownership
################################################################################
FROM ${PYTHON_IMAGE} AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG APP_USER=app
ARG APP_UID=10001
ARG APP_GID=10001
ARG APP_PORT=18200

WORKDIR /app

# Install minimal runtime dependencies: libpq and tini (tini handles signals/child reaping)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libpq5 \
      tini && \
    rm -rf /var/lib/apt/lists/*

# Create unprivileged user/group early so COPY --chown works (requires BuildKit to be effective)
RUN groupadd -g ${APP_GID} ${APP_USER} || true && \
    useradd --uid ${APP_UID} --gid ${APP_GID} --create-home --home-dir /home/${APP_USER} --shell /usr/sbin/nologin ${APP_USER}

# Copy built wheels from builder; copy merged requirements for deterministic install
COPY --from=builder /wheels /wheels
COPY --from=builder /build/merged-requirements.txt /app/merged-requirements.txt

# Install python packages using wheels first to avoid compiling in runtime.
# --find-links points to /wheels; pip will fall back to PyPI for any missing artifacts.
RUN python -m pip install --upgrade pip setuptools wheel && \
    pip install --no-cache-dir --find-links=/wheels -r /app/merged-requirements.txt && \
    pip cache purge

# Copy application source and ensure permissions
# Use --chown with BuildKit (if not available, ownership will be fixed by chown below)
COPY --chown=${APP_UID}:${APP_GID} src /app/src

# Ensure ownership (in case build system didn't honor --chown)
RUN chown -R ${APP_UID}:${APP_GID} /app && chmod -R a+rX /app

# Runtime environment defaults (override at runtime or via build args if needed)
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    LOG_LEVEL=INFO \
    JWT_ISS=agentic-platform \
    JWT_AUD=agent-frontend \
    JWT_EXP_SECONDS=1800 \
    PYTHONPATH=/app \
    PORT=${APP_PORT}

# Expose the service port for documentation purposes (does not publish port)
EXPOSE ${APP_PORT}

# Healthcheck using stdlib urllib (no extra deps required)
# use /ready so health becomes healthy only after DB + providers are ready
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; \
    req=urllib.request.Request('http://127.0.0.1:' + str(${APP_PORT}) + '/ready'); \
    try: r=urllib.request.urlopen(req, timeout=4); sys.exit(0 if r.getcode()==200 else 1) \
    except Exception: sys.exit(1)"

# Use tini as PID 1 to forward signals and reap children, then run as unprivileged user
ENTRYPOINT ["/usr/bin/tini", "--"]

# Switch to non-root user
USER ${APP_UID}:${APP_GID}

# Default command: single-process Uvicorn. Scale horizontally via k8s replicas.
# Tune --limit-concurrency / --timeout / --keep-alive per application needs.
CMD ["uvicorn", "src.services.auth.app:app", "--host", "0.0.0.0", "--port", "18200", "--loop", "asyncio", "--limit-concurrency", "100", "--log-level", "info"]