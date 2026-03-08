import os
import logging
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.langchain import LangchainInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes

def setup_telemetry(app=None):
    service_name = os.getenv("OTEL_SERVICE_NAME", "agentic-agent")
    
    resource = Resource(attributes={
        ResourceAttributes.SERVICE_NAME: service_name,
        ResourceAttributes.SERVICE_VERSION: os.getenv("SERVICE_VERSION", "1.0.0"),
        ResourceAttributes.SERVICE_INSTANCE_ID: os.getenv("HOSTNAME", "unknown"),
        ResourceAttributes.CLOUD_PROVIDER: "kubernetes",
        ResourceAttributes.K8S_CLUSTER_NAME: os.getenv("K8S_CLUSTER_NAME", "unknown"),
        ResourceAttributes.K8S_NAMESPACE_NAME: os.getenv("K8S_NAMESPACE", "ray"),
        ResourceAttributes.K8S_POD_NAME: os.getenv("HOSTNAME", "unknown"),
        ResourceAttributes.K8S_POD_UID: os.getenv("POD_UID", "unknown"),
        ResourceAttributes.CONTAINER_NAME: "ray-worker",
    })
    
    otlp_endpoint = os.getenv(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "http://signoz-otel-collector.signoz.svc.cluster.local:4317"
    )
    
    trace_provider = TracerProvider(resource=resource)
    
    span_exporter = OTLPSpanExporter(
        endpoint=f"{otlp_endpoint}/v1/traces",
        insecure=True,
        timeout=10
    )
    
    span_processor = BatchSpanProcessor(
        span_exporter,
        schedule_delay_millis=5000,
        max_queue_size=2048,
        max_export_batch_size=512
    )
    
    trace_provider.add_span_processor(span_processor)
    trace.set_tracer_provider(trace_provider)
    
    metric_exporter = OTLPMetricExporter(
        endpoint=f"{otlp_endpoint}/v1/metrics",
        insecure=True,
        timeout=10
    )
    
    metric_reader = PeriodicExportingMetricReader(
        metric_exporter,
        export_interval_millis=15000
    )
    
    metric_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(metric_provider)
    
    if app:
        FastAPIInstrumentor.instrument_app(app)
    
    SQLAlchemyInstrumentor().instrument()
    AsyncPGInstrumentor().instrument()
    HTTPXClientInstrumentor().instrument()
    LangchainInstrumentor().instrument()
    
    logging.info("telemetry.initialized", extra={
        "service": service_name,
        "endpoint": otlp_endpoint,
        "cluster": os.getenv("K8S_CLUSTER_NAME", "unknown"),
        "namespace": os.getenv("K8S_NAMESPACE", "ray")
    })
    
    return trace.get_tracer(__name__), metrics.get_meter(__name__)