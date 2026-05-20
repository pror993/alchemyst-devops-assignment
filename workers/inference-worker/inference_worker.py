import os
from typing import Any, Dict, List

from iii import InitOptions, Logger, register_worker
from llama_cpp import Llama
from huggingface_hub import hf_hub_download

iii = register_worker(
    os.environ.get("III_URL", "ws://localhost:49134"),
    InitOptions(worker_name="math-worker"),
)
logger = Logger()

# Download the GGUF model from Hugging Face
model_path = hf_hub_download(
    repo_id="ggml-org/gemma-3-270m-GGUF",
    filename="gemma-3-270m-Q8_0.gguf"
)

# Load the model using llama-cpp
model = Llama(
    model_path=model_path,
    n_ctx=2048,      # context window size
    n_threads=2,     # number of CPU threads
    verbose=False
)

logger.info("Gemma model loaded successfully")

def run_inference_handler(payload: Dict[str, str | List[Dict[str, Any]]]) -> str:
    messages = payload.get("messages", [])

    # llama-cpp handles chat formatting natively
    response = model.create_chat_completion(
        messages=messages,
        max_tokens=512,
    )

    result = response["choices"][0]["message"]["content"]
    print(result)
    return result

iii.register_function("inference::run_inference", run_inference_handler)

print("Inference worker started - listening for calls")