# -----------------------------------------------------------------------------
# Stage 1: Build llama-cpp-python (CPU optimizations)
# -----------------------------------------------------------------------------
FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --target=/install llama-cpp-python==0.1.14 ray[serve]==2.54.0

# -----------------------------------------------------------------------------
# Stage 2: Download Model (Separate layer for caching)
# -----------------------------------------------------------------------------
FROM python:3.11-slim AS model-downloader

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir huggingface_hub==1.5.0

RUN mkdir -p /models && \
    python3 -c "from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='unsloth/Qwen3-1.7B-GGUF', filename='Qwen3-1.7B-Q4_K_M.gguf', local_dir='/models')" || true

# -----------------------------------------------------------------------------
# Stage 3: Runtime (Minimal footprint)
# -----------------------------------------------------------------------------
FROM python:3.11-slim

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libpq5 \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy precompiled llama-cpp-python + ray dependencies
COPY --from=builder /install /usr/local/lib/python3.11/site-packages

# Copy downloaded model
COPY --from=model-downloader /models /models

# Ensure non-root user can read the model files
RUN chmod -R 755 /models

# Install remaining pure-Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --no-deps -r requirements.txt && \
    pip cache purge

# Copy application code
COPY pg_tables.py .
COPY telemetry.py .
COPY llm_serve.py .
COPY agents.py .
COPY main.py .

# Strong defaults matching infrastructure contracts
ENV PYTHONUNBUFFERED=1
ENV LOG_LEVEL=INFO
ENV JWT_ISS=agentic-platform
ENV JWT_AUD=agent-frontend
ENV OTEL_SERVICE_NAME=agentic-agent
ENV OTEL_EXPORTER_OTLP_ENDPOINT=http://signoz-otel-collector.signoz.svc.cluster.local:4317
ENV DATABASE_URL=postgresql://app:password@app-postgres-r.databases.svc.cluster.local:5432/app
ENV MODEL_PATH=/models/Qwen3-1.7B-Q4_K_M.gguf
ENV N_CTX=8192
ENV N_GPU_LAYERS=0
ENV LLAMA_N_THREADS=4
ENV APPROVAL_THRESHOLD=100.0
ENV K8S_CLUSTER_NAME=kind-local
ENV K8S_NAMESPACE=ray

# Security: run as non-root
USER 65534

# Health check validates Ray Serve HTTP endpoint readiness
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import httpx; r = httpx.get('http://localhost:8000/health', timeout=5); exit(0 if r.status_code == 200 else 1)" || exit 1

EXPOSE 8000

# CRITICAL: KubeRay operator manages Ray Serve lifecycle via CRD.
# Container must stay alive while operator initializes Ray runtime.
# DO NOT run 'ray serve run' here - it conflicts with operator control plane.
CMD ["tail", "-f", "/dev/null"]