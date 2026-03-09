# src/services/common/logging.py
"""
Structured JSON logging helpers that inject trace/span IDs.
- Provides a JSONFormatter and TraceContextFilter that extracts current trace/span and puts them into LogRecord.
- get_structured_logger(name, level) returns a logger configured with the formatter.
- Designed to be used by services after init_telemetry(...) so trace context is available.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any, Dict, Optional

# Trace APIs (optional)
try:
    from opentelemetry.trace import get_current_span
except Exception:
    def get_current_span():
        return None  # type: ignore

SERVICE_NAME = os.getenv("SERVICE_NAME", "unknown")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "")


class JSONFormatter(logging.Formatter):
    """
    Produces a compact JSON object per log record with standard fields.
    """
    def formatTime(self, record, datefmt=None):
        # ISO8601 UTC
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(record.created))

    def format(self, record: logging.LogRecord) -> str:
        # Base message
        message = record.getMessage()
        payload: Dict[str, Any] = {
            "timestamp": self.formatTime(record),
            "service.name": SERVICE_NAME,
            "service.version": SERVICE_VERSION,
            "severity": record.levelname,
            "logger": record.name,
            "message": message,
            # event may be attached via record.event
            "event": getattr(record, "event", None),
            # request id if set by middleware
            "reqid": getattr(record, "reqid", None),
        }

        # trace/span if available (TraceContextFilter populates record.trace_id/ span_id)
        trace_id = getattr(record, "trace_id", None)
        span_id = getattr(record, "span_id", None)
        if trace_id:
            payload["trace_id"] = trace_id
        if span_id:
            payload["span_id"] = span_id

        # include extra structured attributes if present (record.attrs or record.json)
        extra = getattr(record, "attrs", None) or {}
        if extra:
            # avoid overriding top-level keys
            payload["attrs"] = extra

        # attach exception info if present
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)

        return json.dumps(payload, default=str, separators=(",", ":"))


class TraceContextFilter(logging.Filter):
    """
    Attach trace_id/span_id from current OpenTelemetry span to the LogRecord.
    Also supports injection of request id from record.reqid if present.
    """
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            span = get_current_span()
            if span is not None:
                ctx = getattr(span, "get_span_context", None)
                if ctx:
                    sc = span.get_span_context()
                    if sc and sc.trace_id:
                        # trace_id is an int; format as 32-char hex according to OTEL
                        record.trace_id = format(sc.trace_id, "032x")
                    else:
                        record.trace_id = None
                    if sc and sc.span_id:
                        record.span_id = format(sc.span_id, "016x")
                    else:
                        record.span_id = None
                else:
                    record.trace_id = None
                    record.span_id = None
            else:
                record.trace_id = None
                record.span_id = None
        except Exception:
            record.trace_id = None
            record.span_id = None
        return True


def get_structured_logger(name: Optional[str] = None, level: Optional[int] = None) -> logging.Logger:
    """
    Return a logger pre-configured with JSONFormatter and TraceContextFilter.
    Note: call init_telemetry(...) before expecting trace IDs in logs.
    """
    logger_name = name or SERVICE_NAME or "app"
    logger = logging.getLogger(logger_name)
    if level is None:
        level = getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper())
    logger.setLevel(level)
    # avoid adding duplicate handlers when called multiple times
    if not any(isinstance(h, logging.StreamHandler) and getattr(h, "_structured", False) for h in logger.handlers):
        sh = logging.StreamHandler()
        sh.setLevel(level)
        sh.setFormatter(JSONFormatter())
        # mark handler so we don't double-add
        setattr(sh, "_structured", True)
        logger.addHandler(sh)
    # ensure filter present
    if not any(isinstance(f, TraceContextFilter) for f in logger.filters):
        logger.addFilter(TraceContextFilter())
    # propagate False so root doesn't double-write
    logger.propagate = False
    return logger