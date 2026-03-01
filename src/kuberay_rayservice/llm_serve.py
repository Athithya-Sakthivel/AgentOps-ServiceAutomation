import os
import sys
import time
import json
import logging
from typing import Any, Dict, List, Optional
from llama_cpp import Llama
import ray
from ray import serve
from ray.serve.batching import Batch

logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper()),
    format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s","logger":"%(name)s"}',
    datefmt="%Y-%m-%dT%H:%M:%S%z"
)
logger = logging.getLogger("llm_serve")

MODEL_PATH = os.getenv("MODEL_PATH", "/models/Qwen3-1.7B-Q4_K_M.gguf")
N_CTX = int(os.getenv("N_CTX", "8192"))
N_GPU_LAYERS = int(os.getenv("N_GPU_LAYERS", "0"))
N_THREADS = int(os.getenv("LLAMA_N_THREADS", "4"))

class LLMModel:
    def __init__(self):
        self.model: Optional[Llama] = None
        logger.info(f"initializing.llm.model_path={MODEL_PATH} n_ctx={N_CTX} n_gpu_layers={N_GPU_LAYERS}")

    def _load_model(self):
        if self.model is None:
            start_time = time.time()
            self.model = Llama(
                model_path=MODEL_PATH,
                n_ctx=N_CTX,
                n_gpu_layers=N_GPU_LAYERS,
                n_threads=N_THREADS,
                verbose=False,
                logits_all=False,
                embedding=False
            )
            load_time = time.time() - start_time
            logger.info(f"model.loaded.in_seconds={load_time:.2f} vocab_size={self.model.n_vocab()}")

    @serve.batch(max_batch_size=16, batch_wait_timeout_s=0.05)
    async def __call__(self, requests: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        self._load_model()
        results = []
        
        for req in requests:
            request_id = req.get("request_id", f"req_{int(time.time()*1000)}_{os.urandom(4).hex()}")
            messages = req.get("messages", [])
            tools = req.get("tools", None)
            max_tokens = req.get("max_tokens", 512)
            temperature = req.get("temperature", 0.1)
            seed = req.get("seed", 42)
            
            logger.info(f"llm.request.start request_id={request_id} messages_count={len(messages)} tools_count={len(tools) if tools else 0}")
            
            if not messages:
                results.append({
                    "request_id": request_id,
                    "success": False,
                    "error": "empty_messages",
                    "content": None,
                    "tool_calls": None
                })
                logger.error(f"llm.request.failed request_id={request_id} error=empty_messages")
                continue
            
            try:
                start_time = time.time()
                response = self.model.create_chat_completion(
                    messages=messages,
                    tools=tools,
                    tool_choice="auto" if tools else None,
                    max_tokens=max_tokens,
                    temperature=temperature,
                    seed=seed,
                    response_format={"type": "json_object"} if tools else None
                )
                inference_time = time.time() - start_time
                
                choice = response["choices"][0]
                message = choice["message"]
                content = message.get("content")
                tool_calls = message.get("tool_calls")
                
                usage = response.get("usage", {})
                prompt_tokens = usage.get("prompt_tokens", 0)
                completion_tokens = usage.get("completion_tokens", 0)
                
                logger.info(
                    f"llm.request.success request_id={request_id} "
                    f"inference_time_ms={inference_time*1000:.1f} "
                    f"prompt_tokens={prompt_tokens} completion_tokens={completion_tokens} "
                    f"content_length={len(content) if content else 0} tool_calls_count={len(tool_calls) if tool_calls else 0}"
                )
                
                results.append({
                    "request_id": request_id,
                    "success": True,
                    "error": None,
                    "content": content,
                    "tool_calls": tool_calls,
                    "usage": usage
                })
                
            except Exception as e:
                logger.error(f"llm.request.failed request_id={request_id} error={str(e)}")
                results.append({
                    "request_id": request_id,
                    "success": False,
                    "error": str(e),
                    "content": None,
                    "tool_calls": None
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
        "runtime_env": {
            "env_vars": {
                "MODEL_PATH": MODEL_PATH,
                "N_CTX": str(N_CTX),
                "N_GPU_LAYERS": str(N_GPU_LAYERS),
                "LLAMA_N_THREADS": str(N_THREADS)
            }
        }
    },
)
class LLMService:
    def __init__(self):
        self.model = LLMModel()

    async def __call__(self, request: Dict[str, Any]) -> Dict[str, Any]:
        return await self.model(request)

app = LLMService.bind()