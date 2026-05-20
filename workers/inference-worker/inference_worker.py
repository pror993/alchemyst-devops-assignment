import os
import httpx
from typing import Any, Dict, List

from iii import InitOptions, Logger, register_worker

iii = register_worker(
    os.environ.get("III_URL", "ws://10.0.0.2:49134"),
    InitOptions(worker_name="math-worker"),
)
logger = Logger()

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
MODEL = os.environ.get("OLLAMA_MODEL", "gemma3:1b")

logger.info(f"Inference worker ready — model: {MODEL}, ollama: {OLLAMA_URL}")


def run_inference_handler(payload: Dict[str, str | List[Dict[str, Any]]]) -> str:
    messages = payload.get("messages", [])

    response = httpx.post(
        f"{OLLAMA_URL}/api/chat",
        json={
            "model": MODEL,
            "messages": messages,
            "stream": False,
        },
        timeout=120.0,
    )
    response.raise_for_status()

    result = response.json()["message"]["content"]
    print(result)
    return result


iii.register_function("inference::run_inference", run_inference_handler)

print("Inference worker started - listening for calls")