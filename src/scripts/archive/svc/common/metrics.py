# src/services/common/metrics.py
"""
Helpers to create standardized OpenTelemetry metrics for services.

Provides:
- standard instrument names (constants)
- ensure_common_instruments(meter) which creates:
    * http.server.requests histogram
    * http.server.request_count counter
    * db.query.duration histogram
    * db.connections.active observable gauge (registration helper)
    * cache.hits_total / cache.misses_total counters (if used)
    * process.* observable metrics skeleton (user must provide callbacks)
- Examples in docstrings show how to use the meter returned by init_telemetry.
"""

from __future__ import annotations
import typing
from typing import Callable

# export consistent metric names for reuse
http_server_request_histogram_name = "http.server.requests"
http_server_request_count_name = "http.server.request_count"
http_client_request_histogram_name = "http.client.requests"
db_query_duration_name = "db.query.duration"
db_connections_active_name = "db.connections.active"
tasks_created_counter_name = "tasks.created_total"
cache_hits_name = "cache.hits_total"
cache_misses_name = "cache.misses_total"
process_cpu_seconds = "process.cpu_seconds_total"
process_memory_bytes = "process.memory_usage_bytes"

# Units and recommended buckets (milliseconds)
_http_buckets_ms = [0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]  # seconds

def ensure_common_instruments(meter):
    """
    Register commonly-used instruments on the supplied meter.

    Returns a dict of instrument objects:
      {
          "http_histogram": ...,
          "http_counter": ...,
          "db_histogram": ...,
          "tasks_counter": ...,
          "cache_hits": ...,
          "cache_misses": ...,
      }
    """
    instruments = {}
    try:
        instruments["http_histogram"] = meter.create_histogram(
            name=http_server_request_histogram_name,
            description="HTTP server request latency (s)",
            unit="s",
        )
    except Exception:
        instruments["http_histogram"] = None

    try:
        instruments["http_counter"] = meter.create_counter(
            name=http_server_request_count_name,
            description="HTTP server request count",
            unit="1",
        )
    except Exception:
        instruments["http_counter"] = None

    try:
        instruments["db_histogram"] = meter.create_histogram(
            name=db_query_duration_name,
            description="DB query duration (s)",
            unit="s",
        )
    except Exception:
        instruments["db_histogram"] = None

    try:
        instruments["tasks_counter"] = meter.create_counter(
            name=tasks_created_counter_name,
            description="Total tasks created",
            unit="1",
        )
    except Exception:
        instruments["tasks_counter"] = None

    try:
        instruments["cache_hits"] = meter.create_counter(
            name=cache_hits_name,
            description="Cache hits",
            unit="1",
        )
        instruments["cache_misses"] = meter.create_counter(
            name=cache_misses_name,
            description="Cache misses",
            unit="1",
        )
    except Exception:
        instruments["cache_hits"] = instruments["cache_misses"] = None

    # Observable gauges (db connections, process metrics) require callbacks from app layer.
    # Provide helper registration functions below if desired.
    return instruments


def register_observable_gauge(meter, name: str, callback: Callable[[], typing.Sequence[typing.Tuple[float, dict]]], description: str = "", unit: str = ""):
    """
    Register an observable gauge where callback returns an iterable of (value, attributes) pairs.
    Usage:
        def db_conn_cb():
            return [(current_pool_size, {"db.system":"postgresql"})]
        register_observable_gauge(meter, db_connections_active_name, db_conn_cb, description="Active PG connections")
    """
    try:
        # API: create_observable_gauge(name, callback=..., unit=..., description=...)
        meter.create_observable_gauge(name=name, callback=lambda obs, ts, ctx: [
            obs.observe(value, attributes) for value, attributes in callback()
        ], description=description, unit=unit)
    except Exception:
        # Some SDKs use create_observable_gauge with different signature; try alternative registration
        try:
            meter.register_callback(lambda obs, ts, ctx: [obs.observe(v, attrs) for v, attrs in callback()], [name])
        except Exception:
            # best-effort: no-op if not supported
            pass