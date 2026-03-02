FROM python:3.13.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip cache purge

COPY auth_server.py .

ENV PYTHONUNBUFFERED=1
ENV LOG_LEVEL=INFO
ENV JWT_ISS=agentic-platform
ENV JWT_AUD=agent-frontend
ENV JWT_EXP_SECONDS=1800

USER 65534

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import httpx; r = httpx.get('http://localhost:8000/auth/health'); exit(0 if r.status_code == 200 else 1)" || exit 1

EXPOSE 8000

CMD ["uvicorn", "auth_server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--log-level", "warning"]