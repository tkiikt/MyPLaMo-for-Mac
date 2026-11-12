"""Compile the real queue/pipeline against a controllable engine test double."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'Sources/LocalTranslate'
# Keep production prompt/types verbatim; substitute only the process-based engine.
prompt = (source / 'InferenceEngine.swift').read_text().split('@MainActor final class InferenceEngine:', 1)[0]
with tempfile.TemporaryDirectory(prefix='myplamo-queue-tests-') as temp:
    temp = Path(temp)
    (temp / 'Prompt.swift').write_text(prompt)
    binary = temp / 'queue-smoke'
    files = ['GlossaryStore.swift', 'DocumentTranslation.swift', 'TranslationSegments.swift', 'TranslationPipeline.swift', 'TranslationQueue.swift']
    subprocess.run(['swiftc', str(temp/'Prompt.swift'), *[str(source/f) for f in files], str(root/'Tests/QueueSmoke.swift'), '-o', str(binary)], check=True, cwd=root)
    subprocess.run([str(binary)], check=True, cwd=root, timeout=90)
