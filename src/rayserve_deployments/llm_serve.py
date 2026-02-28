import json
import logging
import os
import time
from typing import Any, Dict, List, Optional

from llama_cpp import Llama
import ray
from ray import serve

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class LLMModel:
    def __init__(self, model_path: str, n_ctx: int = 8192, n_gpu_layers: int = 0):
        self.model_path = model_path
        self.n_ctx = n_ctx
        self.n_gpu_layers = n_gpu_layers
        self.model: Optional[Llama] = None

    def start(self):
        if self.model is None:
            logger.info(f"Loading model from {self.model_path} n_ctx={self.n_ctx} n_gpu_layers={self.n_gpu_layers}")
            start_time = time.time()
            self.model = Llama(
                model_path=self.model_path,
                n_ctx=self.n_ctx,
                n_gpu_layers=self.n_gpu_layers,
                n_threads=int(os.environ.get("LLAMA_N_THREADS", "4")),
                verbose=False,
            )
            load_time = time.time() - start_time
            logger.info(f"Model loaded in {load_time:.2f}s")

    async def __call__(self, requests: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        self.start()

        results = []
        for request in requests:
            request_id = request.get("request_id", "unknown")
            messages = request.get("messages", [])
            max_tokens = request.get("max_tokens", 512)
            temperature = request.get("temperature", 0.1)
            tools = request.get("tools", None)
            tool_choice = request.get("tool_choice", None)

            logger.info(f"Processing request_id={request_id} messages_count={len(messages)}")

            if not messages:
                logger.error(f"request_id={request_id} error=empty_messages")
                results.append({
                    "request_id": request_id,
                    "success": False,
                    "error": "empty_messages",
                    "content": None,
                    "tool_calls": None,
                })
                continue

            try:
                start_time = time.time()
                response = self.model.create_chat_completion(
                    messages=messages,
                    max_tokens=max_tokens,
                    temperature=temperature,
                    tools=tools,
                    tool_choice=tool_choice,
                    response_format={"type": "json_object"} if tools else None,
                )
                inference_time = time.time() - start_time

                choice = response["choices"][0]
                message = choice["message"]
                content = message.get("content")
                tool_calls = message.get("tool_calls")

                logger.info(
                    f"request_id={request_id} success=True inference_time={inference_time:.3f}s "
                    f"content_length={len(content) if content else 0} tool_calls_count={len(tool_calls) if tool_calls else 0}"
                )

                results.append({
                    "request_id": request_id,
                    "success": True,
                    "error": None,
                    "content": content,
                    "tool_calls": tool_calls,
                    "usage": response.get("usage", {}),
                })

            except Exception as e:
                logger.error(f"request_id={request_id} error={str(e)}")
                results.append({
                    "request_id": request_id,
                    "success": False,
                    "error": str(e),
                    "content": None,
                    "tool_calls": None,
                })

        return results


@serve.deployment(
    name="LLMModel",
    num_replicas=1,
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 10,
        "target_ongoing_requests": 8,
        "target_queued_requests": 4,
        "upscale_delay_s": 10,
        "downscale_delay_s": 300,
    },
    ray_actor_options={
        "num_cpus": 4,
        "num_gpus": 0,
        "memory": 2 * 1024 * 1024 * 1024,
    },
    user_config={
        "max_batch_size": 16,
        "batch_wait_timeout_s": 0.05,
    },
)
class LLMService:
    def __init__(self, model_path: str, n_ctx: int = 8192, n_gpu_layers: int = 0):
        self.model = LLMModel(model_path=model_path, n_ctx=n_ctx, n_gpu_layers=n_gpu_layers)
        self.max_batch_size = 16
        self.batch_wait_timeout_s = 0.05

    def reconfigure(self, user_config: Dict):
        self.max_batch_size = user_config.get("max_batch_size", 16)
        self.batch_wait_timeout_s = user_config.get("batch_wait_timeout_s", 0.05)
        self.model.__call__.set_max_batch_size(self.max_batch_size)
        self.model.__call__.set_batch_wait_timeout_s(self.batch_wait_timeout_s)

    @serve.batch(max_batch_size=16, batch_wait_timeout_s=0.05)
    async def __call__(self, requests: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        return await self.model(requests)


def build_app(model_path: str, n_ctx: int = 8192, n_gpu_layers: int = 0):
    logger.info(f"Building LLM application model_path={model_path} n_ctx={n_ctx} n_gpu_layers={n_gpu_layers}")
    return LLMService.bind(model_path, n_ctx, n_gpu_layers)


if __name__ == "__main__":
    model_path = os.environ.get("MODEL_PATH", "/models/Qwen3-1.7B-Q4_K_M.gguf")
    n_ctx = int(os.environ.get("N_CTX", "8192"))
    n_gpu_layers = int(os.environ.get("N_GPU_LAYERS", "0"))
    serve.run(build_app(model_path, n_ctx, n_gpu_layers), name="llm_app", route_prefix="/llm")
    logger.info(f"LLM service started on /llm n_ctx={n_ctx} n_gpu_layers={n_gpu_layers}")