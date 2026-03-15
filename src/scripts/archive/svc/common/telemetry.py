# src/services/common/telemetry.py
"""
Shared telemetry initialization for traces, metrics and logs.

Design goals:
- Defensive imports to work with a range of OpenTelemetry Python SDK 1.x minor versions.
- Prefer OTLP gRPC exporters (default port 4317) — compatible with Signoz OTLP collector when forwarded.
- Do NOT crash app startup if any telemetry piece is missing; log and continue with sane fallbacks.
- Provide helper functions get_tracer(name) and get_meter(name) for service modules.

Usage:
    from src.services.common.telemetry import init_telemetry, get_tracer, get_meter
    init_telemetry(service_name="auth", service_version="1.0.0")
"""
from __future__ import annotations

import json
import logging
import os
import time
from typing import Dict, Optional

# ---- guarded OpenTelemetry imports ----
# Tracing
try:
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace.sampling import TraceIdRatioBased
    import opentelemetry.trace as trace_api
except Exception:  # pragma: no cover - defensive
    TracerProvider = None
    BatchSpanProcessor = None
    OTLPSpanExporter = None
    TraceIdRatioBased = None
    trace_api = None

# Metrics
try:
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
    import opentelemetry.metrics as metrics_api
except Exception:  # pragma: no cover - defensive
    MeterProvider = None
    PeriodicExportingMetricReader = None
    OTLPMetricExporter = None
    metrics_api = None

# Logs SDK (very version dependent) - we do NOT depend on SDK log processors here.
try:
    # if present, these will be used only for best-effort attempts
    from opentelemetry.sdk._logs import LoggerProvider  # type: ignore
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter  # some versions
except Exception:
    LoggerProvider = None
    OTLPLogExporter = None

# Resource
try:
    from opentelemetry.sdk.resources import Resource
except Exception:
    Resource = None

# ---- module globals ----
_log = logging.getLogger("src.services.common.telemetry")
_TRACER_PROVIDER = None
_METER_PROVIDER = None
_SERVICE_NAME = "unknown"
_SERVICE_VERSION = ""

# ---- helpers ----
def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def _get_env() -> str:
    return os.getenv("DEPLOYMENT_ENV", os.getenv("ENVIRONMENT", "development"))

def _default_otlp_endpoint_from_env() -> Optional[str]:
    # Accept either explicit OTEL_EXPORTER_OTLP_ENDPOINT (host:port) or OTEL_EXPORTER_OTLP_ENDPOINTS
    ep = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") or os.getenv("OTEL_EXPORTER_OTLP_ENDPOINTS")
    if not ep:
        return None
    # normalize: ensure port exists if just host
    if ":" not in ep:
        return f"{ep}:4317"
    return ep

def get_resource_attributes(service_name: str, service_version: Optional[str] = None) -> Dict[str, str]:
    attrs = {
        "service.name": service_name,
        "deployment.environment": _get_env(),
    }
    if service_version:
        attrs["service.version"] = service_version
    # include some k8s-like env vars if present
    for env_k, attr_k in (("KUBE_NAMESPACE", "k8s.namespace"), ("KUBE_POD_NAME", "k8s.pod.name"), ("KUBE_NODE_NAME", "k8s.node.name")):
        v = os.getenv(env_k)
        if v:
            attrs[attr_k] = v
    return attrs

# ---- logging JSON formatter + trace injection ----
class TraceInjectingFilter(logging.Filter):
    """
    Logging filter that injects trace_id and span_id (hex) into LogRecord.
    We fetch current span via opentelemetry.trace.get_current_span() if available.
    This keeps structured logging correlated to traces without relying on SDK log exporters.
    """
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            # opentelemetry.trace API may or may not be present
            if trace_api is not None:
                span = trace_api.get_current_span()
                if span is not None:
                    ctx = getattr(span, "get_span_context", None)
                    if ctx:
                        sc = span.get_span_context()
                        trace_id = getattr(sc, "trace_id", 0)
                        span_id = getattr(sc, "span_id", 0)
                        # convert to 16/32 hex strings if present and non-zero
                        record.__dict__.setdefault("trace_id", f"{trace_id:032x}" if trace_id else "")
                        record.__dict__.setdefault("span_id", f"{span_id:016x}" if span_id else "")
            # ensure fields exist
            record.__dict__.setdefault("trace_id", "")
            record.__dict__.setdefault("span_id", "")
        except Exception:
            record.__dict__.setdefault("trace_id", "")
            record.__dict__.setdefault("span_id", "")
        return True

class JsonLoggingFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": _now_iso(),
            "service.name": _SERVICE_NAME,
            "service.version": _SERVICE_VERSION or "",
            "severity": record.levelname,
            "logger": record.name,
            # message may already be JSON sometimes; keep as string
            "message": record.getMessage(),
            # optional correlation fields commonly used in these services
            "event": getattr(record, "event", None),
            "reqid": getattr(record, "reqid", None),
            "trace_id": getattr(record, "trace_id", ""),
            "span_id": getattr(record, "span_id", ""),
        }
        # include any extra attributes found on the record (not standard ones)
        extras = {
            k: v for k, v in record.__dict__.items()
            if k not in ("name","msg","args","levelname","levelno","pathname","filename","module",
                         "exc_info","exc_text","stack_info","lineno","funcName","created","msecs",
                         "relativeCreated","thread","threadName","processName","process","message",
                         "event","reqid","trace_id","span_id")
        }
        if extras:
            payload["extra"] = extras
        return json.dumps(payload, default=str)

def configure_structured_logging(service_name: str, service_version: Optional[str] = None, level: int = logging.INFO) -> None:
    """
    Configure root logger to emit JSON structured logs and inject trace/span ids.
    Call early (immediately after init_telemetry).
    """
    global _SERVICE_NAME, _SERVICE_VERSION
    _SERVICE_NAME = service_name
    _SERVICE_VERSION = service_version or ""
    root = logging.getLogger()
    root.setLevel(level)
    # clear any handlers in test/dev contexts to avoid double logs
    if not any(isinstance(h, logging.StreamHandler) for h in root.handlers):
        stream = logging.StreamHandler()
        stream.setLevel(level)
        fmt = JsonLoggingFormatter()
        stream.setFormatter(fmt)
        root.addHandler(stream)
    # add the trace injection filter if not present
    if not any(isinstance(f, TraceInjectingFilter) for f in root.filters):
        root.addFilter(TraceInjectingFilter())

# ---- init function ----
def init_telemetry(
    service_name: str,
    service_version: Optional[str] = None,
    otlp_endpoint: Optional[str] = None,
    otlp_insecure: bool = True,
    trace_sampler_rate: float = 0.01,
    metrics_export_interval_s: int = 15,
    log_level: int = logging.INFO,
) -> None:
    """
    Initialize tracing, metrics and structured logging.
    This function is resilient: if a particular exporter or SDK piece isn't available, it logs and continues.

    Important: call early in app startup (before external calls) so automatic instrumentation can pick up the provider.
    """
    global _TRACER_PROVIDER, _METER_PROVIDER, _SERVICE_NAME, _SERVICE_VERSION

    _SERVICE_NAME = service_name
    _SERVICE_VERSION = service_version or ""

    endpoint = otlp_endpoint or _default_otlp_endpoint_from_env()

    # Resource (best-effort)
    resource = None
    if Resource is not None:
        try:
            resource = Resource.create(get_resource_attributes(service_name, service_version))
        except Exception:
            resource = None

    # --- tracing ---
    if TracerProvider is not None and BatchSpanProcessor is not None and OTLPSpanExporter is not None and trace_api is not None:
        try:
            # instantiate provider with sampler if available
            try:
                sampler = TraceIdRatioBased(trace_sampler_rate) if TraceIdRatioBased is not None else None
                if sampler is not None:
                    provider = TracerProvider(resource=resource, sampler=sampler)
                else:
                    provider = TracerProvider(resource=resource) if resource is not None else TracerProvider()
            except Exception:
                # fallback to simple constructor if sampler assignment fails
                provider = TracerProvider(resource=resource) if resource is not None else TracerProvider()

            exporter_kwargs = {}
            if endpoint:
                exporter_kwargs["endpoint"] = endpoint
            # insecure flag is accepted by many OTLP exporters; pass only if truthy
            if otlp_insecure:
                exporter_kwargs.setdefault("insecure", True)
            span_exporter = OTLPSpanExporter(**exporter_kwargs)
            provider.add_span_processor(BatchSpanProcessor(span_exporter))
            trace_api.set_tracer_provider(provider)
            _TRACER_PROVIDER = provider
            _log.info("telemetry: tracing initialized; otlp=%s", bool(endpoint))
        except Exception as exc:
            _log.exception("telemetry: failed to initialize tracing: %s", exc)
    else:
        _log.debug("telemetry: tracing SDK or exporter not available")

    # --- metrics ---
    if MeterProvider is not None and PeriodicExportingMetricReader is not None and OTLPMetricExporter is not None and metrics_api is not None:
        try:
            metric_exporter_kwargs = {}
            if endpoint:
                metric_exporter_kwargs["endpoint"] = endpoint
            if otlp_insecure:
                metric_exporter_kwargs.setdefault("insecure", True)
            metric_exporter = OTLPMetricExporter(**metric_exporter_kwargs)
            metric_reader = PeriodicExportingMetricReader(metric_exporter, export_interval_millis=int(metrics_export_interval_s * 1000))
            meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
            metrics_api.set_meter_provider(meter_provider)
            _METER_PROVIDER = meter_provider
            _log.info("telemetry: metrics initialized; otlp=%s", bool(endpoint))
        except Exception as exc:
            _log.exception("telemetry: failed to initialize metrics: %s", exc)
    else:
        _log.debug("telemetry: metrics SDK or exporter not available")

    # --- logs: structured logging configuration + best-effort SDK exporter (non-blocking) ---
    try:
        configure_structured_logging(service_name, service_version, level=log_level)
        _log.info("telemetry: structured logging configured (trace->logs injection enabled)")
    except Exception:
        _log.exception("telemetry: failed to configure structured logging")

    # Attempt to attach OTLP log exporter to SDK logger provider if available - best-effort only
    if LoggerProvider is not None and OTLPLogExporter is not None:
        try:
            # Using SDK logger provider is risky across versions; do best-effort and swallow errors
            logger_provider = LoggerProvider(resource=resource) if resource is not None else LoggerProvider()
            log_exporter_kwargs = {}
            if endpoint:
                log_exporter_kwargs["endpoint"] = endpoint
            if otlp_insecure:
                log_exporter_kwargs.setdefault("insecure", True)
            log_exporter = OTLPLogExporter(**log_exporter_kwargs)
            # Add processor if SDK provides BatchLogRecordProcessor
            try:
                from opentelemetry.sdk._logs import BatchLogRecordProcessor  # type: ignore
                logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))  # type: ignore
            except Exception:
                # older/newer SDKs may not expose a convenient batched processor; skip silently
                _log.debug("telemetry: OTLP log export via SDK not attached; SDK log processor API mismatch")
            try:
                import opentelemetry._logs as logs_api  # type: ignore
                logs_api.set_logger_provider(logger_provider)
                _log.info("telemetry: OTLP log exporter attached to SDK (best-effort)")
            except Exception:
                _log.debug("telemetry: failed to set SDK logger provider (best-effort); continuing")
        except Exception:
            _log.debug("telemetry: OTLPLogExporter available but failed to attach (best-effort)")

def get_tracer(name: Optional[str] = None, version: Optional[str] = None):
    """
    Return a tracer. Always safe to call even if tracing is not configured.
    """
    # prefer configured provider
    try:
        if _TRACER_PROVIDER is not None:
            return _TRACER_PROVIDER.get_tracer(name or _SERVICE_NAME, version)
    except Exception:
        pass
    # fallback to API-level tracer
    try:
        return trace_api.get_tracer(name or _SERVICE_NAME, version)
    except Exception:
        return None

def get_meter(name: Optional[str] = None):
    """
    Return a meter. Safe to call even if metrics are not configured.
    """
    try:
        if _METER_PROVIDER is not None:
            return _METER_PROVIDER.get_meter(name or _SERVICE_NAME)
    except Exception:
        pass
    try:
        return metrics_api.get_meter(name or _SERVICE_NAME)
    except Exception:
        return None