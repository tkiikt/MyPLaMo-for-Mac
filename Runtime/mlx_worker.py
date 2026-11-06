#!/usr/bin/env python3
"""Offline, single-thread MLX worker. stdin/stdout are a JSON Lines protocol.

Input: {id, model_path, prompt, max_tokens?, device?: "gpu"|"cpu"}
Output: {id,type:"token",text}, then {id,type:"done",finish_reason,...};
        or {id,type:"error",message}. The parent cancels by terminating us.
Only verified PFN local model directories should be supplied by the app.
"""
from __future__ import annotations

import contextlib
import gc
import json
import os
from pathlib import Path
import sys
import traceback

# A local translation must never trigger a background Hub or telemetry request.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ.setdefault("NUMBA_NUM_THREADS", "4")

# Save protocol FD before redirecting Python and native-library diagnostics.
# Writing protocol via a duplicated fd also keeps dependency print() calls out.
_PROTOCOL = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
sys.stdout = sys.stderr


def emit(request_id, kind, **fields):
    _PROTOCOL.write(json.dumps({"id": request_id, "type": kind, **fields}, ensure_ascii=False) + "\n")
    _PROTOCOL.flush()


class Worker:
    def __init__(self):
        import mlx.core as mx
        from mlx_lm import load, stream_generate
        from mlx_lm.sample_utils import make_sampler
        self.mx, self.load, self.generate, self.make_sampler = mx, load, stream_generate, make_sampler
        self.model = self.tokenizer = self.configuration = None

    def run(self, request):
        request_id = request.get("id")
        if not isinstance(request_id, (str, int)) or isinstance(request_id, bool):
            raise ValueError("A string or integer request id is required")
        prompt = request.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 100_000:
            raise ValueError("prompt must contain between 1 and 100000 characters")
        maximum = request.get("max_tokens", 8192)
        if not isinstance(maximum, int) or isinstance(maximum, bool) or not 1 <= maximum <= 8192:
            raise ValueError("max_tokens must be between 1 and 8192")
        device = request.get("device", "gpu")
        if device not in ("gpu", "cpu"):
            raise ValueError("device must be gpu or cpu")
        supplied_path = request.get("model_path")
        if not isinstance(supplied_path, str) or not supplied_path:
            raise ValueError("model_path must be an existing local directory")
        path = Path(supplied_path).expanduser().resolve(strict=True)
        if not path.is_dir() or not (path / "config.json").is_file() or not any(path.glob("*.safetensors")):
            raise ValueError("The local MLX model directory is incomplete")
        if device == "gpu" and not self.mx.metal.is_available():
            raise ValueError("Apple Metal GPU is not available")
        compute_device = self.mx.gpu if device == "gpu" else self.mx.cpu
        self.mx.set_default_device(compute_device)
        configuration = (str(path), device)
        if self.configuration != configuration:
            self.model = self.tokenizer = self.configuration = None
            gc.collect()
            self.mx.clear_cache()
            # PFN's MLX implementation/tokenizer ships as verified local source.
            self.model, self.tokenizer = self.load(
                str(path), trust_remote_code=True,
                tokenizer_config={"trust_remote_code": True, "local_files_only": True},
            )
            self.tokenizer.add_eos_token("<|plamo:tag|>")
            self.tokenizer.add_eos_token("<|plamo:bos|>")
            self.configuration = configuration
        tokens = self.tokenizer.encode(prompt, add_special_tokens=not prompt.startswith("<|plamo:bos|>"))
        if len(tokens) + maximum > 32768:
            raise ValueError("Input plus requested output exceeds the 32768-token model context")
        # Give both loading and generation the requested device. Using only
        # set_default_device is insufficient: mlx-lm caches a generation stream.
        stream = self.mx.new_stream(compute_device)
        final = None
        for response in self.generate(
            self.model, self.tokenizer, prompt=tokens, max_tokens=maximum,
            sampler=self.make_sampler(temp=0), stream=stream,
        ):
            if response.text:
                emit(request_id, "token", text=response.text)
            final = response
        if final is None or final.finish_reason not in ("stop", "length"):
            raise RuntimeError("MLX generation ended without a completion reason")
        emit(request_id, "done", finish_reason=final.finish_reason,
             prompt_tokens=final.prompt_tokens, generation_tokens=final.generation_tokens,
             device=device)


def main():
    worker = None
    for line in sys.stdin:
        request_id = None
        try:
            if len(line) > 1_000_000:
                raise ValueError("Request exceeds the protocol limit")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Request must be a JSON object")
            request_id = request.get("id")
            if worker is None:
                worker = Worker()
            worker.run(request)
        except BrokenPipeError:
            return
        except Exception as error:
            # Do not include source text, prompt or model weights in error output.
            emit(request_id, "error", message=f"{type(error).__name__}: {error}")
            traceback.print_exc(file=sys.stderr)


if __name__ == "__main__":
    main()
